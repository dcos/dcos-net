-module(dcos_rest_dns_handler).

-export([
    init/3,
    rest_init/2,
    allowed_methods/2,
    content_types_provided/2,
    process/2
]).

-include_lib("dns/include/dns.hrl").
-include_lib("erldns/include/erldns.hrl").

init(_Transport, Req, Opts) ->
    {upgrade, protocol, cowboy_rest, Req, Opts}.

rest_init(Req, Opts) ->
    {ok, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, process}
    ], Req, State}.

process(Req, State = [version]) ->
    Applications = application:which_applications(),
    {dcos_dns, _V, Version} = lists:keyfind(dcos_dns, 1, Applications),
    Body =
        jsx:encode(#{
            <<"Service">> => <<"dcos_dns">>,
            <<"Version">> => list_to_binary(Version)
        }),
    {Body, Req, State};

process(Req, State = [config]) ->
    reply_halt(501, Req, State); % TODO

process(Req, State = [hosts]) ->
    {Host, Req0} = cowboy_req:binding(host, Req),
    DNSQuery = #dns_query{name = Host, type = ?DNS_TYPE_A},
    #dns_message{answers = Answers} = handle(DNSQuery, Host),
    Data =
        [ #{<<"host">> => Name, <<"ip">> => ntoa(Ip)}
        || #dns_rr{name = Name, type = ?DNS_TYPE_A,
                   data = #dns_rrdata_a{ip = Ip}} <- Answers],
    {jsx:encode(Data), Req0, State};

process(Req, State = [services]) ->
    {Service, Req0} = cowboy_req:binding(service, Req),
    DNSQuery = #dns_query{name = Service, type = ?DNS_TYPE_SRV},
    #dns_message{answers = Answers} = handle(DNSQuery, Service),
    Data = lists:map(fun srv_record_to_term/1, Answers),
    {jsx:encode(Data), Req0, State};

process(Req, State = [enumerate]) ->
    reply_halt(501, Req, State); % TODO

process(Req, State = [records]) ->
    {{chunked, records_fun()}, Req, State}.

records_fun() ->
    fun (SendFun) ->
        ok = SendFun("["),
        ZonesV = erldns_zone_cache:zone_names_and_versions(),
        Zones = [Z || {Z, _} <- ZonesV],
        records_fun(SendFun, [], Zones, 0),
        ok = SendFun("]")
    end.

records_fun(_SendFun, [], [], N) ->
    N;
records_fun(SendFun, [], [Zone|Zones], N) ->
    case erldns_zone_cache:get_zone_with_records(Zone) of
        {ok, #zone{records = Records}} ->
            records_fun(SendFun, Records, Zones, N);
        {error, zone_not_found} ->
            records_fun(SendFun, [], Zones, N)
    end;
records_fun(SendFun, [Record|Records], Zones, 0) ->
    {ok, Inc} = send_record(SendFun, "", Record),
    records_fun(SendFun, Records, Zones, Inc);
records_fun(SendFun, [Record|Records], Zones, N) ->
    {ok, Inc} = send_record(SendFun, ",\n", Record),
    records_fun(SendFun, Records, Zones, N + Inc).

reply_halt(StatusCode, Req, State) ->
    {ok, Req0} = cowboy_req:reply(StatusCode, Req),
    {halt, Req0, State}.

send_record(SendFun, Prefix, RR) ->
    try jsx:encode(record_to_term(RR)) of
        Data ->
            {SendFun([Prefix, Data]), 1}
    catch throw:unknown_record_type ->
        {ok, 0}
    end.

-spec handle(dns:query(), binary()) -> dns:message().
handle(DNSQuery, Host) ->
    DNSMessage = #dns_message{
        rd = true, ad = true,
        qc = 1, questions = [DNSQuery],
        adc = 1, additional = [#dns_optrr{}]},
    erldns_handler:handle(DNSMessage, {http, Host}).

-spec srv_record_to_term(dns:rr()) -> jsx:json_term().
srv_record_to_term(Record) ->
    #dns_rr{
        name = Name, type = ?DNS_TYPE_SRV,
        data = #dns_rrdata_srv{
            port = Port, target = Target}
    } = Record,
    Json = #{
        <<"host">> => Target,
        <<"port">> => Port,
        <<"service">> => Name
    },
    case resolve(Target) of
        {ok, IpAddress} ->
            Json#{<<"ip">> => ntoa(IpAddress)};
        error ->
            Json
    end.

-spec resolve(binary()) -> {ok, inet:ip_address()} | error.
resolve(Host) ->
    DNSQuery = #dns_query{name = Host, type = ?DNS_TYPE_A},
    case handle(DNSQuery, Host) of
        #dns_message{answers = [Answer|_]} ->
            #dns_rr{type = ?DNS_TYPE_A,
                    data = #dns_rrdata_a{ip = Ip}} = Answer,
            {ok, Ip};
        _Else ->
            error
    end.

-spec record_to_term(dns:rr()) -> jsx:json_term().
record_to_term(#dns_rr{
        name = Name, type = ?DNS_TYPE_A,
        data = #dns_rrdata_a{ip = Ip}}) ->
    #{<<"name">> => Name,
      <<"host">> => ntoa(Ip),
      <<"rtype">> => <<"A">>};
record_to_term(#dns_rr{
        name = Name, type = ?DNS_TYPE_SRV,
        data = #dns_rrdata_srv{port = Port, target = Target}}) ->
    PortBin = integer_to_binary(Port),
    Host = <<Target/binary, ":", PortBin/binary>>,
    #{<<"name">> => Name,
      <<"host">> => Host,
      <<"rtype">> => <<"SRV">>};
record_to_term(_RR) ->
    throw(unknown_record_type).

-spec ntoa(inet:ip_address()) -> binary().
ntoa(Ip) ->
    list_to_binary(inet:ntoa(Ip)).
