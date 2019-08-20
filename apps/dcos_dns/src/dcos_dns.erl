-module(dcos_dns).

-include_lib("kernel/include/logger.hrl").
-include("dcos_dns.hrl").
-include_lib("dns/include/dns_records.hrl").
-include_lib("erldns/include/erldns.hrl").

%% API
-export([
    family/1,
    resolve/1,
    resolve/2,
    resolve/3,
    get_leader_addr/0,
    init_metrics/0
]).

%% DNS Zone functions
-export([
    ns_record/1,
    soa_record/1,
    dns_record/2,
    dns_records/2,
    srv_record/2,
    cname_record/2,
    push_zone/2,
    push_prepared_zone/2
]).

-spec family(inet:ip_address()) -> inet | inet6.
family(IP) when size(IP) == 4 ->
    inet;
family(IP) when size(IP) == 8 ->
    inet6.

-spec(get_leader_addr() -> {ok, inet:ip_address()} | {error, term()}).
get_leader_addr() ->
    case resolve(<<"leader.mesos">>, inet) of
        {ok, [IP]} ->
            {ok, IP};
        {ok, _IPs} ->
            {error, not_found};
        {error, Error} ->
            {error, Error}
    end.

-spec(resolve(binary()) -> {ok, [inet:ip_address()]} | {error, term()}).
resolve(DNSName) ->
    resolve(DNSName, inet).

-spec(resolve(binary(), inet | inet6) ->
    {ok, [inet:ip_address()]} | {error, term()}).
resolve(DNSName, Family) ->
    resolve(DNSName, Family, 5000).

-spec(resolve(binary(), inet | inet6, timeout()) ->
    {ok, [inet:ip_address()]} | {error, term()}).
resolve(DNSName, Family, Timeout) ->
    DNSNameStr = binary_to_list(DNSName),
    ParseFun =
        case Family of
            inet -> fun inet:parse_ipv4_address/1;
            inet6 -> fun inet:parse_ipv6_address/1
        end,
    case ParseFun(DNSNameStr) of
        {ok, IP} ->
            {ok, [IP]};
        {error, einval} ->
            imp_resolve(DNSName, Family, Timeout)
    end.

-spec(imp_resolve(binary(), inet | inet6, timeout()) ->
    {ok, [inet:ip_address()]} | {error, term()}).
imp_resolve(<<"localhost">>, inet, _Timeout) ->
    {ok, [{127, 0, 0, 1}]};
imp_resolve(DNSName, Family, Timeout) ->
    Type =
        case Family of
            inet -> ?DNS_TYPE_A;
            inet6 -> ?DNS_TYPE_AAAA
        end,
    Query = #dns_query{name = DNSName, type = Type},
    Message = #dns_message{rd = true, qc = 1, questions = [Query]},
    Request = dns:encode_message(Message),
    case dcos_dns_handler:resolve(udp, Request, Timeout) of
        {ok, Response} ->
            try dns:decode_message(Response) of #dns_message{answers = RRs} ->
                DataRRs = [D || #dns_rr{data = D} <- RRs],
                {ok, [IP || #dns_rrdata_a{ip = IP} <- DataRRs] ++
                     [IP || #dns_rrdata_aaaa{ip = IP} <- DataRRs]}
            catch Class:Error ->
                {error, {Class, Error}}
            end;
        {error, Error} ->
            {error, Error}
    end.

%%%===================================================================
%%% DNS Zone functions
%%%===================================================================

-spec(soa_record(dns:dname()) -> dns:dns_rr()).
soa_record(Name) ->
    #dns_rr{
        name = Name,
        type = ?DNS_TYPE_SOA,
        ttl = 5,
        data = #dns_rrdata_soa{
            mname = <<"ns.spartan">>, %% Nameserver
            rname = <<"support.mesosphere.com">>,
            serial = 1,
            refresh = 60,
            retry = 180,
            expire = 86400,
            minimum = 1
        }
    }.

-spec(ns_record(dns:dname()) -> dns:dns_rr()).
ns_record(Name) ->
    #dns_rr{
        name = Name,
        type = ?DNS_TYPE_NS,
        ttl = 3600,
        data = #dns_rrdata_ns{
            dname = <<"ns.spartan">>
        }
    }.

-spec(dns_records(dns:dname(), [inet:ip_address()]) -> [dns:dns_rr()]).
dns_records(DName, IPs) ->
    [dns_record(DName, IP) || IP <- IPs].

-spec(dns_record(dns:dname(), inet:ip_address()) -> dns:dns_rr()).
dns_record(DName, IP) ->
    {Type, Data} =
        case dcos_dns:family(IP) of
            inet -> {?DNS_TYPE_A, #dns_rrdata_a{ip = IP}};
            inet6 -> {?DNS_TYPE_AAAA, #dns_rrdata_aaaa{ip = IP}}
        end,
    #dns_rr{name = DName, type = Type, ttl = ?DCOS_DNS_TTL, data = Data}.

-spec(srv_record(dns:dname(), {dns:dname(), inet:port_number()}) -> dns:rr()).
srv_record(DName, {Host, Port}) ->
    #dns_rr{
        name = DName,
        type = ?DNS_TYPE_SRV,
        ttl = ?DCOS_DNS_TTL,
        data = #dns_rrdata_srv{
            target = Host,
            port = Port,
            weight = 1,
            priority = 1
        }
    }.

-spec(cname_record(dns:dname(), dns:dname()) -> dns:dns_rr()).
cname_record(CName, Name) ->
    #dns_rr{
        name = CName,
        type = ?DNS_TYPE_CNAME,
        ttl = 5,
        data = #dns_rrdata_cname{dname=Name}
    }.

-spec(push_zone(dns:dname(), Records) -> ok | {error, Reason :: term()}
    when Records :: [dns:dns_rr()] | #{dns:dname() => [dns:dns_rr()]}).
push_zone(ZoneName, Records) ->
    Begin = erlang:monotonic_time(),
    Records0 = [ns_record(ZoneName), soa_record(ZoneName) | Records],
    RecordsByName = build_named_index(Records0),
    try erldns_zone_cache:get_zone_with_records(ZoneName) of
        {ok, #zone{records_by_name=RecordsByName}} ->
            ok;
        _Other ->
            Zone = build_zone(ZoneName, RecordsByName),
            push_prepared_zone(Begin, ZoneName, Zone)
    catch error:Error ->
        ?LOG_ERROR(
            "Failed to push DNS Zone \"~s\": ~p",
            [ZoneName, Error]),
        {error, Error}
    end.

-spec(push_prepared_zone(dns:dname(), Records) -> ok | {error, term()}
    when Records :: [dns:dns_rr()] | #{dns:dname() => [dns:dns_rr()]}).
push_prepared_zone(ZoneName, Records) ->
    Begin = erlang:monotonic_time(),
    Zone = build_zone(ZoneName, Records),
    push_prepared_zone(Begin, ZoneName, Zone).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(push_prepared_zone(Begin, dns:dname(), Zone) -> ok | {error, term()}
    when Begin :: integer(), Zone :: erldns:zone()).
push_prepared_zone(Begin, ZoneName, Zone) ->
    try
        ok = erldns_storage:insert(zones, {ZoneName, Zone}),
        ZoneName0 = <<ZoneName/binary, ".">>,
        Duration = erlang:monotonic_time() - Begin,
        DurationMs = erlang:convert_time_unit(Duration, native, millisecond),
        #zone{record_count = RecordCount} = Zone,
        ?LOG_NOTICE(
            "DNS Zone ~s was updated (~p records, duration: ~pms)",
            [ZoneName0, RecordCount, DurationMs]),
        prometheus_summary:observe(
            dns, zone_push_duration_seconds,
            [ZoneName0], Duration),
        prometheus_gauge:set(
            dns, zone_records,
            [ZoneName0], RecordCount)
    catch error:Error ->
        ?LOG_ERROR(
            "Failed to push DNS Zone \"~s\": ~p",
            [ZoneName, Error]),
        {error, Error}
    end.

-spec(build_zone(dns:dname(), Records) -> erldns:zone()
    when Records :: [dns:dns_rr()] | #{dns:dname() => [dns:dns_rr()]}).
build_zone(ZoneName, Records) ->
    Time = erlang:system_time(second),
    Version = calendar:system_time_to_rfc3339(Time),
    RecordsByName = build_named_index(Records),
    RecordCounts = lists:map(fun length/1, maps:values(RecordsByName)),
    Authorities = lists:filter(
        erldns_records:match_type(?DNS_TYPE_SOA),
        maps:get(ZoneName, RecordsByName)),
    #zone{
        name = ZoneName,
        version = list_to_binary(Version),
        record_count = lists:sum(RecordCounts),
        authority = Authorities,
        records_by_name = RecordsByName,
        keysets = []
    }.

-spec(build_named_index([dns:rr()] | RecordsByName) -> RecordsByName
    when RecordsByName :: #{dns:dname() => [dns:rr()]}).
build_named_index(RecordsByName) when is_map(RecordsByName) ->
    RecordsByName;
build_named_index(Records) ->
    lists:foldl(fun (#dns_rr{name = Name} = RR, Acc) ->
        RRs = maps:get(Name, Acc, []),
        Acc#{Name => [RR | RRs]}
    end, #{}, Records).

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(init_metrics() -> ok).
init_metrics() ->
    prometheus_gauge:new([
        {registry, dns},
        {name, zone_records},
        {labels, [zone]},
        {help, "The number of records in DNS Zone."}]),
    prometheus_summary:new([
        {registry, dns},
        {name, zone_push_duration_seconds},
        {labels, [zone]},
        {duration_unit, seconds},
        {help, "The time spent pushing DNS Zone to the zone cache."}]).
