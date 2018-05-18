-module(dcos_rest_dns_handler).

-export([
    init/2,
    rest_init/2,
    allowed_methods/2,
    content_types_provided/2,

    version/2,
    config/2,
    hosts/2,
    services/2,
    enumerate/2,
    records/2
]).

-include_lib("dns/include/dns.hrl").
-include_lib("erldns/include/erldns.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

rest_init(Req, Opts) ->
    {ok, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, [Fun]) ->
    {[
        {{<<"application">>, <<"json">>, []}, Fun}
    ], Req, []}.

version(Req, State) ->
    Applications = application:which_applications(),
    {dcos_dns, _V, Version} = lists:keyfind(dcos_dns, 1, Applications),
    Body =
        jsx:encode(#{
            <<"Service">> => <<"dcos-dns">>,
            <<"Version">> => list_to_binary(Version)
        }),
    {Body, Req, State}.

config(Req, State) ->
    % TODO
    Req0 = cowboy_req:reply(501, Req),
    {stop, Req0, State}.

hosts(Req, State) ->
    Host = cowboy_req:binding(host, Req),
    DNSQuery = #dns_query{name = Host, type = ?DNS_TYPE_A},
    #dns_message{answers = Answers} = handle(DNSQuery, Host),
    Data =
        [ #{<<"host">> => Name, <<"ip">> => ntoa(Ip)}
        || #dns_rr{name = Name, type = ?DNS_TYPE_A,
                   data = #dns_rrdata_a{ip = Ip}} <- Answers],
    {jsx:encode(Data), Req, State}.

services(Req, State) ->
    Service = cowboy_req:binding(service, Req),
    DNSQuery = #dns_query{name = Service, type = ?DNS_TYPE_SRV},
    #dns_message{answers = Answers} = handle(DNSQuery, Service),
    Data = lists:map(fun srv_record_to_term/1, Answers),
    {jsx:encode(Data), Req, State}.

enumerate(Req, State) ->
    % TODO
    Req0 = cowboy_req:reply(501, Req),
    {stop, Req0, State}.

records(Req, State) ->
    Req0 = cowboy_req:stream_reply(200, Req),
    ok = cowboy_req:stream_body("[", nofin, Req0),
    ZonesV = erldns_zone_cache:zone_names_and_versions(),
    Zones = [Z || {Z, _} <- ZonesV],
    ok = records_loop(Req0, [], Zones, 0),
    ok = cowboy_req:stream_body("]", fin, Req0),
    {stop, Req0, State}.

records_loop(_Req, [], [], _N) ->
    ok;
records_loop(Req, [], [Zone|Zones], N) ->
    case erldns_zone_cache:get_zone_with_records(Zone) of
        {ok, #zone{records = Records}} ->
            records_loop(Req, Records, Zones, N);
        {error, zone_not_found} ->
            records_loop(Req, [], Zones, N)
    end;
records_loop(Req, [Record|Records], Zones, 0) ->
    Inc = send_record(Req, "", Record),
    records_loop(Req, Records, Zones, Inc);
records_loop(Req, [Record|Records], Zones, N) ->
    Inc = send_record(Req, ",\n", Record),
    records_loop(Req, Records, Zones, N + Inc).

send_record(Req, Prefix, RR) ->
    try jsx:encode(record_to_term(RR)) of
        Data ->
            ok = cowboy_req:stream_body([Prefix, Data], nofin, Req),
            1
    catch throw:unknown_record_type ->
        0
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
        name = Name, type = ?DNS_TYPE_AAAA,
        data = #dns_rrdata_aaaa{ip = Ip}}) ->
    #{<<"name">> => Name,
      <<"host">> => ntoa(Ip),
      <<"rtype">> => <<"AAAA">>};
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
