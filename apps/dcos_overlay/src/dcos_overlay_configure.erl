-module(dcos_overlay_configure).

-export([
    start_link/1,
    stop/1,
    maybe_configure/2,
    configure_overlay/2
]).

-type subnet() :: dcos_overlay_lashup_kv_listener:subnet().
-type config() :: dcos_overlay_lashup_kv_listener:config().

-spec(start_link(config()) -> pid()).
start_link(Config) ->
   Pid = self(),
   proc_lib:spawn_link(?MODULE, maybe_configure, [Pid, Config]).

-spec(stop(pid()) -> ok).
stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    ok.

-spec(maybe_configure(pid(), config()) -> term()).
maybe_configure(Pid, Config) ->
    {ok, Netlink} = dcos_overlay_netlink:start_link(),
    try
        lists:foreach(fun (Overlay) ->
            maybe_configure_overlay(Netlink, Config, Overlay)
        end, dcos_overlay_poller:overlays()),
        Pid ! {dcos_overlay_configure, applied_config, Config}
    after
        dcos_overlay_netlink:stop(Netlink)
    end.

-spec(maybe_configure_overlay(pid(), config(), jiffy:json_term()) -> ok).
maybe_configure_overlay(Pid, Config, #{<<"info">> := OverlayInfo} = Overlay) ->
    Subnet = maps:get(<<"subnet">>, OverlayInfo, undefined),
    #{<<"backend">> := #{<<"vxlan">> := VxLan}} = Overlay,
    #{<<"vtep_name">> := VTEPName} = VxLan,
    ok = maybe_configure_overlay(Pid, VTEPName, Config, Subnet),
    case application:get_env(dcos_overlay, enable_ipv6, true) of
        true ->
            Subnet6 = maps:get(<<"subnet6">>, OverlayInfo, undefined),
            ok = maybe_configure_overlay(Pid, VTEPName, Config, Subnet6);
        false ->
            ok
    end.

-spec(maybe_configure_overlay(pid(), binary(), config(), undefined) -> ok).
maybe_configure_overlay(_Pid, _VTEPName, _Config, undefined) ->
    ok;
maybe_configure_overlay(Pid, VTEPName, Config, Subnet) ->
    ParsedSubnet = parse_subnet(Subnet),
    case maps:find(ParsedSubnet, Config) of
        {ok, OverlayConfig} ->
            lists:foreach(fun ({VTEPIPPrefix, Data}) ->
                maybe_configure_overlay_entry(
                    Pid, VTEPName, VTEPIPPrefix, Data)
            end, OverlayConfig);
        error ->
            ok
    end.

-spec(maybe_configure_overlay_entry(pid(), binary(), subnet(), map()) -> ok).
maybe_configure_overlay_entry(Pid, VTEPName, VTEPIPPrefix, Data) ->
    LocalIP = dcos_overlay_poller:ip(),
    case maps:get(agent_ip, Data) of
        LocalIP ->
            ok;
        _AgentIP ->
            configure_overlay_entry(Pid, VTEPName, VTEPIPPrefix, Data)
    end.

-spec(configure_overlay_entry(pid(), binary(), subnet(), map()) -> ok).
configure_overlay_entry(Pid, VTEPName, {VTEPIP, _PrefixLen}, Data) ->
    #{
        mac := MAC,
        agent_ip := AgentIP,
        subnet := {SubnetIP, SubnetPrefixLen}
    } = Data,
    VTEPNameStr = binary_to_list(VTEPName),
    Args = [AgentIP, VTEPNameStr, VTEPIP, MAC, SubnetIP, SubnetPrefixLen],
    ?MODULE:configure_overlay(Pid, Args).

-spec(configure_overlay(pid(), [term()]) -> ok).
configure_overlay(Pid, Args) ->
    [AgentIP, VTEPNameStr, VTEPIP, MAC, SubnetIP, SubnetPrefixLen] = Args,
    MACTuple = list_to_tuple(MAC),
    Family = dcos_l4lb_app:family(SubnetIP),
    {ok, _} = dcos_overlay_netlink:ipneigh_replace(
                Pid, Family, VTEPIP, MACTuple, VTEPNameStr),
    {ok, _} = dcos_overlay_netlink:iproute_replace(
                Pid, Family, SubnetIP, SubnetPrefixLen, VTEPIP, main),
    case Family of
        inet ->
            {ok, _} = dcos_overlay_netlink:bridge_fdb_replace(
                        Pid, AgentIP, MACTuple, VTEPNameStr),
            {ok, _} = dcos_overlay_netlink:iproute_replace(
                        Pid, Family, AgentIP, 32, VTEPIP, 42),
            ok;
        _Family  ->
            ok
    end.

-spec(parse_subnet(binary()) -> subnet()).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 128,
    {IP, PrefixLen}.
