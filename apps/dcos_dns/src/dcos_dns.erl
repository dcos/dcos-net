-module(dcos_dns).

-include_lib("dns/include/dns_records.hrl").

%% API
-export([
    family/1,
    resolve/1,
    resolve/2,
    resolve/3,
    get_leader_addr/0
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
    {ok, inet:ip_address()} | {error, term()}).
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
