-module(dcos_rest_vips_handler).

-export([
    init/3,
    allowed_methods/2,
    content_types_provided/2,
    process/2
]).

-include_lib("dcos_l4lb/include/dcos_l4lb.hrl").

init(_Transport, Req, Opts) ->
    {upgrade, protocol, cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, process}
    ], Req, State}.

process(Req, State) ->
    {Value, VClock} = lashup_kv:value2(?VIPS_KEY2),
    VClockHash = base64:encode(crypto:hash(sha, term_to_binary(VClock))),
    Req0 = cowboy_req:set_resp_header(<<"ETag">>, VClockHash, Req),
    {to_json(Value), Req0, State}.

to_json(VIPs) ->
    Data = lists:map(fun vip_to_json_term/1, VIPs),
    jsx:encode(Data).

vip_to_json_term({VIP, Backend}) ->
    {Name, Protocol} = vip(VIP),
    #{
        vip => Name,
        protocol => Protocol,
        backend => lists:map(fun backend/1, Backend)
    }.

vip({{Protocol, VIP, Port}, riak_dt_orswot}) ->
    vip({Protocol, VIP, Port});
vip({Protocol, {name, {Id, Framework}}, Port}) ->
    [ZoneName|_ZoneNames] = ?ZONE_NAMES,
    FullName = mesos_state:domain_frag([Id, Framework | ZoneName]),
    vip(Protocol, FullName, Port);
vip({Protocol, IP, Port}) ->
    vip(Protocol, ip(IP), Port).

vip(Protocol, FullName, Port) ->
    PortBin = integer_to_binary(Port),
    {<<FullName/binary, ":", PortBin/binary>>, Protocol}.

backend({_AgentIP, {IP, Port}}) ->
    #{
        ip => ip(IP),
        port => Port
    }.

ip(IP) ->
    list_to_binary(lists:flatten(inet:ntoa(IP))).
