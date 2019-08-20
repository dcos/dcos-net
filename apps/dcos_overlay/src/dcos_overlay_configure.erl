-module(dcos_overlay_configure).

-export([
    start_link/1,
    stop/1,
    apply_config/2,
    configure_overlay/2
]).

-include_lib("kernel/include/logger.hrl").

-type subnet() :: dcos_overlay_lashup_kv_listener:subnet().
-type config() :: dcos_overlay_lashup_kv_listener:config().

-spec(start_link(config()) -> pid()).
start_link(Config) ->
    Pid = self(),
    proc_lib:spawn_link(?MODULE, apply_config, [Pid, Config]).

-spec(stop(pid()) -> ok).
stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    ok.

-spec(apply_config(pid(), config()) -> ok | {error, term()}).
apply_config(Pid, Config) ->
    case apply_config(Config) of
        ok ->
            Pid ! {dcos_overlay_configure, applied_config, Config},
            ok;
        {error, Error} ->
            Pid ! {dcos_overlay_configure, failed, Error, Config},
            {error, Error}
    end.

-spec(apply_config(config()) -> ok | {error, term()}).
apply_config(Config) ->
    case dcos_overlay_netlink:start_link() of
        {ok, Netlink} ->
            try maybe_configure(Netlink, Config) of
                ok ->
                    ok;
                {error, Error} ->
                    ?LOG_ERROR(
                        "Failed to apply overlay config ~p due to ~p",
                        [Config, Error]),
                    {error, Error}
            catch
                Class:Error:StackTrace ->
                    ?LOG_ERROR(
                        "Failed to apply overlay config ~p due to ~p",
                        [Config, {Class, Error, StackTrace}]),
                    {error, {Class, Error}}
            after
                dcos_overlay_netlink:stop(Netlink)
            end;
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to apply overlay config ~p due to ~p",
                [Config, Error]),
            {error, Error}
    end.

-spec(maybe_configure(pid(), config()) -> ok | {error, term()}).
maybe_configure(Netlink, Config) ->
    lists:foldl(
        fun (Overlay, ok) ->
                case maybe_configure_overlay(Netlink, Config, Overlay) of
                    ok ->
                        ok;
                    {error, Error} ->
                        ?LOG_ERROR(
                            "Failed to configure overlay ~p due to ~p",
                            [Overlay, Error]),
                        {error, Error}
                end;
            (_, {error, Error}) ->
                {error, Error}
        end, ok, dcos_overlay_poller:overlays()).

-spec(maybe_configure_overlay(pid(), config(), jiffy:json_term()) ->
    ok | {error, term()}).
maybe_configure_overlay(Pid, Config, #{<<"info">> := OverlayInfo} = Overlay) ->
    Subnet = maps:get(<<"subnet">>, OverlayInfo, undefined),
    #{<<"backend">> := #{<<"vxlan">> := VxLan}} = Overlay,
    #{<<"vtep_name">> := VTEPName} = VxLan,
    case maybe_configure_overlay(Pid, VTEPName, Config, Subnet) of
        ok ->
            case application:get_env(dcos_overlay, enable_ipv6, true) of
                true ->
                    Subnet6 = maps:get(<<"subnet6">>, OverlayInfo, undefined),
                    maybe_configure_overlay(Pid, VTEPName, Config, Subnet6);
                false ->
                    ok
            end;
        {error, Error} ->
            {error, Error}
    end.

-spec(maybe_configure_overlay(pid(), binary(), config(), undefined) ->
    ok | {error, term()}).
maybe_configure_overlay(_Pid, _VTEPName, _Config, undefined) ->
    ok;
maybe_configure_overlay(Pid, VTEPName, Config, Subnet) ->
    ParsedSubnet = parse_subnet(Subnet),
    case maps:find(ParsedSubnet, Config) of
        {ok, OverlayConfig} ->
            maybe_configure_overlay_entries(Pid, VTEPName, OverlayConfig);
        error ->
            ok
    end.

maybe_configure_overlay_entries(_Pid, _VTEPName, [] = _OverlayConfig) ->
    ok;
maybe_configure_overlay_entries(Pid, VTEPName, OverlayConfig0) ->
    [{VTEPIPPrefix, Data} | OverlayConfig] = OverlayConfig0,
    case maybe_configure_overlay_entry(Pid, VTEPName, VTEPIPPrefix, Data) of
        ok ->
            maybe_configure_overlay_entries(Pid, VTEPName, OverlayConfig);
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to configure overlay for VTEP IP "
                "prefix: ~p; data: ~p; due to ~p",
                [VTEPIPPrefix, Data, Error]),
            {error, Error}
    end.

-spec(maybe_configure_overlay_entry(pid(), binary(), subnet(), map()) ->
    ok | {error, term()}).
maybe_configure_overlay_entry(Pid, VTEPName, VTEPIPPrefix, Data) ->
    LocalIP = dcos_overlay_poller:ip(),
    case maps:get(agent_ip, Data) of
        LocalIP ->
            ok;
        _AgentIP ->
            configure_overlay_entry(Pid, VTEPName, VTEPIPPrefix, Data)
    end.

-spec(configure_overlay_entry(pid(), binary(), subnet(), map()) ->
    ok | {error, term()}).
configure_overlay_entry(Pid, VTEPName, {VTEPIP, _PrefixLen}, Data) ->
    #{mac := MAC, agent_ip := AgentIP,
        subnet := {SubnetIP, SubnetPrefixLen}} = Data,
    VTEPNameStr = binary_to_list(VTEPName),
    Args = [AgentIP, VTEPNameStr, VTEPIP, MAC, SubnetIP, SubnetPrefixLen],
    ?MODULE:configure_overlay(Pid, Args).

-spec(configure_overlay(pid(), [term()]) -> ok | {error, term()}).
configure_overlay(Pid, Args) ->
    [AgentIP, VTEPNameStr, VTEPIP, MAC, SubnetIP, SubnetPrefixLen] = Args,
    MACTuple = list_to_tuple(MAC),
    Family = dcos_l4lb_app:family(SubnetIP),
    configure_overlay_ipneigh_replace(
        Pid, Family, AgentIP, VTEPNameStr, VTEPIP, MAC, SubnetIP,
        SubnetPrefixLen, MACTuple).

configure_overlay_ipneigh_replace(Pid, Family, AgentIP, VTEPNameStr, VTEPIP,
    MAC, SubnetIP, SubnetPrefixLen, MACTuple) ->
    case dcos_overlay_netlink:ipneigh_replace(
             Pid, Family, VTEPIP, MACTuple, VTEPNameStr) of
        {ok, _} ->
            configure_overlay_subnet_iproute_replace(
                Pid, Family, AgentIP, VTEPNameStr, VTEPIP, SubnetIP,
                SubnetPrefixLen, MACTuple);
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to create or replace a neighbor table entry for "
                "family: ~p; VTEP IP: ~p; MAC: ~p, VTEP name: ~s due to ~p",
                [Family, VTEPIP, MAC, VTEPNameStr, Error]),
            {error, Error}
    end.

configure_overlay_subnet_iproute_replace(Pid, Family, AgentIP, VTEPNameStr,
    VTEPIP, SubnetIP, SubnetPrefixLen, MACTuple) ->
    case dcos_overlay_netlink:iproute_replace(
             Pid, Family, SubnetIP, SubnetPrefixLen, VTEPIP, main) of
        {ok, _} ->
            case Family of
                inet ->
                    configure_overlay_bridge_fdb_replace(
                        Pid, Family, AgentIP, VTEPNameStr, VTEPIP, MACTuple);
                _Family -> ok
            end;
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to create or replace a network route for "
                "family: ~p; subnet IP: ~p/~p; VTEP IP: ~p due to ~p",
                [Family, SubnetIP, SubnetPrefixLen, VTEPIP, Error]),
            {error, Error}
    end.

configure_overlay_bridge_fdb_replace(
  Pid, Family, AgentIP, VTEPNameStr, VTEPIP, MACTuple) ->
    case dcos_overlay_netlink:bridge_fdb_replace(
             Pid, AgentIP, MACTuple, VTEPNameStr) of
        {ok, _} ->
            configure_overlay_agent_iproute_replace(Pid, Family, AgentIP, VTEPIP);
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to create or replace a neighbor table entry for "
                "agent IP: ~p; MAC: ~p, VTEP name: ~s due to ~p",
                [AgentIP, MACTuple, VTEPNameStr, Error]),
            {error, Error}
    end.

configure_overlay_agent_iproute_replace(Pid, Family, AgentIP, VTEPIP) ->
    case dcos_overlay_netlink:iproute_replace(
             Pid, Family, AgentIP, 32, VTEPIP, 42) of
        {ok, _} -> ok;
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to create or replace a network route for "
                "family: ~p; agent IP: ~p; VTEP IP: ~p due to ~p",
                [Family, AgentIP, VTEPIP, Error]),
            {error, Error}
    end.

-spec(parse_subnet(binary()) -> subnet()).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 128,
    {IP, PrefixLen}.
