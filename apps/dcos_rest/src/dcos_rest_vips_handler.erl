-module(dcos_rest_vips_handler).

-include_lib("dcos_l4lb/include/dcos_l4lb.hrl").

-export([
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    process/2
]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, process}
    ], Req, State}.

process(Req, State) ->
    {Value, VClock} = lashup_kv:value2(?VIPS_KEY3),
    VIPs =
        case lists:keyfind(?VIPS_FIELD, 1, Value) of
            false -> #{};
            {?VIPS_FIELD, V} -> V
        end,
    VClockHash = base64:encode(crypto:hash(sha, term_to_binary(VClock))),
    Req0 = cowboy_req:set_resp_header(<<"ETag">>, VClockHash, Req),
    {to_json(VIPs), Req0, State}.

to_json(VIPs) ->
    Data = maps:fold(fun to_json_fold/3, [], VIPs),
    jiffy:encode(Data).

to_json_fold(VIP, Backends, Acc) ->
    [vip_to_json_term(VIP, Backends) | Acc].

vip_to_json_term(VIP, Backends) ->
    {Name, Protocol} = vip(VIP),
    #{
        vip => Name,
        protocol => Protocol,
        backend => lists:flatmap(fun backends/1, Backends)
    }.

vip({Protocol, {Id, Framework}, Port}) ->
    List = [Id, Framework | ?L4LB_ZONE_NAME],
    FullName = dcos_l4lb_lashup_vip_listener:to_name(List),
    vip(Protocol, FullName, Port);
vip({Protocol, IP, Port}) ->
    vip(Protocol, ip(IP), Port).

vip(Protocol, FullName, Port) ->
    PortBin = integer_to_binary(Port),
    {<<FullName/binary, ":", PortBin/binary>>, Protocol}.

backends(#{host_port := HostPort, agent_ip := AgentIP}) ->
    [#{ip => ip(AgentIP), port => HostPort}];
backends(#{port := Port, task_ip := TaskIPs}) ->
    [#{ip => ip(IP), port => Port} || IP <- TaskIPs].

ip(IP) ->
    list_to_binary(lists:flatten(inet:ntoa(IP))).
