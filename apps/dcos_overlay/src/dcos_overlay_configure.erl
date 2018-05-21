%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 9:27 PM
%%%-------------------------------------------------------------------
-module(dcos_overlay_configure).
-author("sdhillon").
-author("dgoel").

%% API
-export([start_link/1, stop/1, maybe_configure/2]).

-type config() :: #{key := term(), value := term()}.

-spec(start_link(config()) -> pid()).
start_link(Config) ->
   MyPid = self(),
   spawn_link(?MODULE, maybe_configure, [Config, MyPid]).

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

reply(Pid, Msg) ->
    Pid ! Msg.

-spec(maybe_configure(config(), pid()) -> term()).
maybe_configure(Config, MyPid) ->
    lager:debug("Started applying config ~p~n", [Config]),
    KnownOverlays = dcos_overlay_poller:overlays(),
    {ok, Netlink} = dcos_overlay_netlink:start_link(),
    lists:map(
        fun(Overlay) -> try_configure_overlay(Netlink, Config, Overlay) end,
        KnownOverlays
    ),
    dcos_overlay_netlink:stop(Netlink),
    lager:debug("Done applying config ~p for overlays ~p~n", [Config, KnownOverlays]),
    reply(MyPid, {dcos_overlay_configure, applied_config, Config}).

-spec(try_configure_overlay(Pid :: pid(), config(), jiffy:json_term()) -> term()).
try_configure_overlay(Pid, Config, Overlay) ->
    #{<<"info">> := OverlayInfo} = Overlay,
    Subnet = maps:get(<<"subnet">>, OverlayInfo, undefined),
    try_configure_overlay(Pid, Config, Overlay, Subnet),
    case application:get_env(dcos_overlay, enable_ipv6, true) of
      true ->
        Subnet6 = maps:get(<<"subnet6">>, OverlayInfo, undefined),
        try_configure_overlay(Pid, Config, Overlay, Subnet6);
      false -> ok
    end.

try_configure_overlay(_Pid, _Config, _Overlay, undefined) ->
    ok;
try_configure_overlay(Pid, Config, Overlay, Subnet) ->
    ParsedSubnet = parse_subnet(Subnet),
    try_configure_overlay2(Pid, Config, Overlay, ParsedSubnet).

-type prefix_len() :: 0..32.
-spec(parse_subnet(Subnet :: binary()) -> {inet:ipv4_address(), prefix_len()}).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 128,
    {IP, PrefixLen}.

try_configure_overlay2(Pid, #{key := [navstar, overlay, Subnet],
                              value := Config}, Overlay, Subnet) ->
    ok = collect_metrics(Subnet, Config),
    lists:foreach(fun (Value) ->
        maybe_configure_overlay_entry(Pid, Overlay, Value)
    end, Config);
try_configure_overlay2(_Pid, _Config, _Overlay, _Subnet) ->
    ok.

maybe_configure_overlay_entry(Pid, Overlay, {{VTEPIPPrefix, riak_dt_map}, Value}) ->
    MyIP = dcos_overlay_poller:ip(),
    case lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, Value) of
        {_, MyIP} ->
            ok;
        _Any ->
            configure_overlay_entry(Pid, Overlay, VTEPIPPrefix, Value)
    end.

configure_overlay_entry(Pid, Overlay, _VTEPIPPrefix = {VTEPIP, _PrefixLen}, LashupValue) ->
    #{<<"backend">> := #{<<"vxlan">> := #{<<"vtep_name">> := VTEPName}}} = Overlay,
    {_, MAC} = lists:keyfind({mac, riak_dt_lwwreg}, 1, LashupValue),
    {_, AgentIP} = lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, LashupValue),
    {_, {SubnetIP, SubnetPrefixLen}} = lists:keyfind({subnet, riak_dt_lwwreg}, 1, LashupValue),

    %% TEST only : writes the parameters to a file
    maybe_print_parameters([AgentIP, binary_to_list(VTEPName),
                            VTEPIP, MAC, SubnetIP, SubnetPrefixLen]),

    VTEPNameStr = binary_to_list(VTEPName),
    MACTuple = list_to_tuple(MAC),
    Family = determine_family(inet:ntoa(SubnetIP)),
    {ok, _} = dcos_overlay_netlink:ipneigh_replace(Pid, Family, VTEPIP, MACTuple, VTEPNameStr),
    {ok, _} = dcos_overlay_netlink:iproute_replace(Pid, Family, SubnetIP, SubnetPrefixLen, VTEPIP, main),
    case Family of
      inet ->
        {ok, _} = dcos_overlay_netlink:bridge_fdb_replace(Pid, AgentIP, MACTuple, VTEPNameStr),
        {ok, _} = dcos_overlay_netlink:iproute_replace(Pid, Family, AgentIP, 32, VTEPIP, 42);
      _  ->
         ok
    end.

determine_family(IP) ->
    case inet:parse_ipv4_address(IP) of
      {ok, _} -> inet;
      _ -> inet6
    end.

-ifdef(TEST).
maybe_print_parameters(Parameters) ->
    {ok, PrivDir} = application:get_env(dcos_overlay, outputdir),
    File = filename:join(PrivDir, node()),
    ok = file:write_file(File, io_lib:fwrite("~p.\n", [Parameters]), [append]).

-else.
maybe_print_parameters(_) ->
    ok.
-endif.

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(collect_metrics(Subnet | undefined | binary(), OverlayConfig) -> ok
    when Subnet :: dcos_overlay_poller:subnet(), OverlayConfig :: list()).
collect_metrics(undefined, _Config) ->
    ok;
collect_metrics(Name, Config) when is_binary(Name) ->
    folsom_metrics:notify(
        {overlay, network, Name, updated},
        {inc, 1}, counter),
    folsom_metrics:notify(
        {overlay, network, Name, routes},
        length(Config), gauge);
collect_metrics(Subnet, Config) ->
    Name = dcos_overlay_poller:subnet2name(Subnet),
    collect_metrics(Name, Config).
