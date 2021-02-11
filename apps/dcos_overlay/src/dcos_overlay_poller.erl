%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 9:27 PM
%%%-------------------------------------------------------------------
-module(dcos_overlay_poller).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0, ip/0, overlays/0, init_metrics/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).

-define(MIN_POLL_PERIOD, 30000).  %% 30  secs
-define(MAX_POLL_PERIOD, 120000). %% 120 secs

-define(VXLAN_UDP_PORT, 64000).

-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("gen_netlink/include/netlink.hrl").

-define(TABLE, 42).

-record(state, {
    known_overlays = ordsets:new(),
    ip = undefined :: undefined | inet:ip4_address(),
    backoff :: non_neg_integer(),
    timer_ref = make_ref() :: reference(),
    netlink :: undefined | pid()
}).

%%%===================================================================
%%% API
%%%===================================================================

ip() ->
    gen_server:call(?SERVER, ip).

overlays() ->
    gen_server:call(?SERVER, overlays).

%% @doc Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, [], {continue, init}}.

handle_call(ip, _From, State = #state{ip = IP}) ->
    {reply, IP, State};
handle_call(overlays, _From, State = #state{known_overlays = KnownOverlays}) ->
    {reply, KnownOverlays, State};
handle_call(Request, _From, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {reply, ok, State}.

handle_cast(Request, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {noreply, State}.

handle_info({timeout, TimerRef, poll}, #state{timer_ref = TimerRef} = State) ->
    {noreply, State, {continue, poll}};
handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_continue(init, []) ->
    State = handle_init(),
    {noreply, State, {continue, poll}};
handle_continue(poll, State0) ->
    State = handle_poll(State0),
    {noreply, State, hibernate}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_init() ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    #state{backoff = ?MIN_POLL_PERIOD, netlink = Pid}.

handle_poll(#state{netlink = Pid, known_overlays = Overlays,
        backoff = Backoff0} = State) ->
    case poll() of
        {error, _Error} ->
            TimerRef = backoff_fire(Backoff0),
            Backoff = backoff_reset(),
            State#state{backoff = Backoff, timer_ref = TimerRef};
        {ok, AgentInfo} ->
            case parse_response(Pid, Overlays, AgentInfo) of
                {ok, NewOverlays, AgentIP} ->
                    TimerRef = backoff_fire(Backoff0),
                    Backoff = backoff_bump(Backoff0),
                    State#state{ip = AgentIP, backoff = Backoff,
                        known_overlays = NewOverlays, timer_ref = TimerRef};
                {error, Error} ->
                    ?LOG_ERROR(
                      "Failed to parse overlay response due to ~p", [Error]),
                    exit(Error)
            end
    end.

backoff_reset() ->
    ?MIN_POLL_PERIOD.

backoff_bump(Backoff) ->
    min(?MAX_POLL_PERIOD, 2 * Backoff).

backoff_fire(Backoff) ->
    erlang:start_timer(Backoff, self(), poll).

poll() ->
    Begin = erlang:monotonic_time(),
    try dcos_net_mesos:poll("/overlay-agent/overlay") of
        {error, Error} ->
            prometheus_counter:inc(overlay, poll_errors_total, [], 1),
            ?LOG_WARNING("Overlay Poller could not poll: ~p", [Error]),
            {error, Error};
        {ok, Data} ->
            {ok, Data}
    after
        prometheus_summary:observe(overlay, poll_duration_seconds, [],
            erlang:monotonic_time() - Begin)
    end.

parse_response(Pid, KnownOverlays, AgentInfo) ->
    AgentIP0 = maps:get(<<"ip">>, AgentInfo),
    AgentIP = process_ip(AgentIP0),
    Overlays = maps:get(<<"overlays">>, AgentInfo, []),
    NewOverlays = Overlays -- KnownOverlays,
    Results = [add_overlay(Pid, Overlay, AgentIP) || Overlay <- NewOverlays],
    {Successes, Failures} =
        lists:partition(fun (ok) -> true; (_) -> false end, Results),
    prometheus_gauge:set(overlay, networks_configured, [],
        length(Successes) + length(KnownOverlays)),
    case Failures of
        [] ->
            {ok, NewOverlays ++ KnownOverlays, AgentIP};
        [Error | _Rest] ->
            prometheus_counter:inc(
                overlay, network_configuration_failures_total, [],
                length(Failures)),
            Error
    end.

process_ip(IPBin0) ->
    [IPBin1|_MaybePort] = binary:split(IPBin0, <<":">>),
    IPStr = binary_to_list(IPBin1),
    {ok, IP} = inet:parse_ipv4_address(IPStr),
    IP.

add_overlay(Pid,
    Overlay = #{<<"backend">> := #{<<"vxlan">> := VxLan},
                <<"state">> := #{<<"status">> := <<"STATUS_OK">>}},
    AgentIP) ->
    ?LOG_NOTICE("Configuring new overlay network, ~p", [VxLan]),
    case config_overlay(Pid, Overlay) of
        ok ->
            case maybe_add_overlay_to_lashup(Overlay, AgentIP) of
                ok ->
                    ok;
                {error, Error} ->
                    ?LOG_ERROR(
                        "Failed to add overlay ~p to Lashup due to ~p",
                        [Overlay, Error]),
                    {error, Error}
            end;
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to configure overlay ~p due to ~p",
                [Overlay, Error]),
            {error, Error}
    end;
add_overlay(_Pid, Overlay, _AgentIP) ->
    ?LOG_WARNING("Bad overlay network was skipped, ~p", [Overlay]),
    ok.

config_overlay(Pid, Overlay) ->
    case maybe_create_vtep(Pid, Overlay) of
        ok ->
            case maybe_add_ip_rule(Pid, Overlay) of
                ok -> ok;
                {error, Error} ->
                    ?LOG_ERROR(
                        "Failed to add IP rule for overlay ~p due to ~p",
                        [Overlay, Error]),
                    {error, Error}
            end;
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to create VTEP link for overlay ~p due to ~p",
                [Overlay, Error]),
            {error, Error}
    end.

mget(Key, Map) ->
    maps:get(Key, Map, undefined).

maybe_create_vtep(Pid, #{<<"backend">> := Backend}) ->
    #{<<"vxlan">> := VXLan} = Backend,
    case maybe_create_vtep_link(Pid, VXLan) of
        ok ->
            case create_vtep_addr(Pid, VXLan) of
                ok -> ok;
                {error, Error} ->
                    ?LOG_ERROR(
                        "Failed to create VTEP address for ~p due to ~p",
                        [VXLan, Error]),
                    {error, Error}
            end;
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to create VTEP link for ~p due to ~p",
                [VXLan, Error]),
            {error, Error}
    end.

maybe_create_vtep_link(Pid, VXLan) ->
    #{<<"vtep_name">> := VTEPName} = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    case check_vtep_link(Pid, VXLan) of
        {ok, false} ->
            ?LOG_INFO(
                "Overlay VTEP link will be created, ~s",
                [VTEPNameStr]),
            create_vtep_link(Pid, VXLan);
        {ok, {true, true}} ->
            ?LOG_INFO(
                "Overlay VTEP link is up-to-date, ~s",
                [VTEPNameStr]),
            ok;
        {ok, {true, false}} ->
            ?LOG_INFO(
                "Overlay VTEP link is not up-to-date, and will be "
                "recreated, ~s", [VTEPNameStr]),
            recreate_vtep_link(Pid, VXLan, VTEPNameStr);
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to check VTEP link ~s due to ~p",
                [VTEPNameStr, Error]),
            {error, Error}
    end.

check_vtep_link(Pid, VXLan) ->
    #{<<"vtep_name">> := VTEPName} = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    case dcos_overlay_netlink:iplink_show(Pid, VTEPNameStr) of
        {ok, [#rtnetlink{type=newlink, msg=Msg}]} ->
            {unspec, arphrd_ether, _, _, _, LinkInfo} = Msg,
            Match = match_vtep_link(VXLan, LinkInfo),
            {ok, {true, Match}};
        {error, {enodev, _ErrorMsg}} ->
            ?LOG_INFO("Overlay VTEP link does not exist, ~s", [VTEPName]),
            {ok, false};
        {error, Error} ->
            {error, Error}
    end.

match_vtep_link(VXLan, Link) ->
    #{<<"vni">> := VNI,
      <<"vtep_mac">> := VTEPMAC} = VXLan,
    Expected =
        [{address, binary:list_to_bin(parse_vtep_mac(VTEPMAC))},
         {linkinfo, [{kind, "vxlan"},
                     {data, [{id, VNI}, {port, ?VXLAN_UDP_PORT}]}]}],
    VTEPMTU = mget(<<"vtep_mtu">>, VXLan),
    Expected2 = Expected ++ [{mtu, VTEPMTU} || is_integer(VTEPMTU)],
    match(Expected2, Link).

match(Expected, List) when is_list(Expected) ->
    lists:all(fun (KV) -> match(KV, List) end, Expected);
match({K, V}, List) ->
    case lists:keyfind(K, 1, List) of
        false -> false;
        {K, V} -> true;
        {K, V0} -> match(V, V0)
    end;
match(_Attr, _List) ->
    false.

create_vtep_link(Pid, VXLan) ->
    #{<<"vni">> := VNI,
      <<"vtep_mac">> := VTEPMAC,
      <<"vtep_name">> := VTEPName} = VXLan,
    VTEPMTU = mget(<<"vtep_mtu">>, VXLan),
    VTEPNameStr = binary_to_list(VTEPName),
    ParsedVTEPMAC = list_to_tuple(parse_vtep_mac(VTEPMAC)),
    VTEPAttr = [{mtu, VTEPMTU} || is_integer(VTEPMTU)],
    case dcos_overlay_netlink:iplink_add(
             Pid, VTEPNameStr, "vxlan", VNI, ?VXLAN_UDP_PORT, VTEPAttr) of
        {ok, _} ->
            case dcos_overlay_netlink:iplink_set(
                     Pid, ParsedVTEPMAC, VTEPNameStr) of
                {ok, _} ->
                    Info = #{vni => VNI, mac => VTEPMAC, attr => VTEPAttr},
                    ?LOG_NOTICE(
                        "Overlay VTEP link was configured, ~s => ~p",
                        [VTEPName, Info]),
                    ok;
                {error, Error} ->
                    ?LOG_ERROR(
                        "Failed to set VTEP link for MAC: ~p; VTEP: ~s "
                        "due to ~p", [ParsedVTEPMAC, VTEPNameStr, Error]),
                    {error, Error}
            end;
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to add VTEP link for VTEP: ~s; VNI: ~p due to ~p",
                [VTEPNameStr, VNI, Error]),
            {error, Error}
    end.

recreate_vtep_link(Pid, VXLan, VTEPNameStr) ->
    case dcos_overlay_netlink:iplink_delete(Pid, VTEPNameStr) of
        {ok, _} ->
            ?LOG_NOTICE("Overlay VTEP link was removed, ~s", [VTEPNameStr]),
            create_vtep_link(Pid, VXLan);
        {error, {enodev, _ErrorMsg}} ->
            ?LOG_NOTICE("Overlay VTEP link did not exist, ~s", [VTEPNameStr]),
            create_vtep_link(Pid, VXLan);
        {error, Error}  ->
            ?LOG_ERROR(
                "Failed to detete VTEP link ~s due to ~p",
                [VTEPNameStr, Error]),
            {error, Error}
    end.

create_vtep_addr(Pid, VXLan) ->
    #{<<"vtep_ip">> := VTEPIP,
      <<"vtep_name">> := VTEPName} = VXLan,
    VTEPIP6 = mget(<<"vtep_ip6">>, VXLan),
    VTEPNameStr = binary_to_list(VTEPName),
    {ParsedVTEPIP, PrefixLen} = parse_subnet(VTEPIP),
    case dcos_overlay_netlink:ipaddr_replace(
             Pid, inet, ParsedVTEPIP, PrefixLen, VTEPNameStr) of
        {ok, _} ->
            ?LOG_NOTICE("Overlay VTEP address was configured, ~s => ~p",
                [VTEPName, VTEPIP]),
            maybe_create_vtep_addr6(Pid, VTEPName, VTEPNameStr, VTEPIP6);
        {error, Error}  ->
            ?LOG_ERROR(
                "Failed to replace address ~p for VTEP ~s due to ~p",
                [VTEPIP, VTEPNameStr, Error]),
            {error, Error}
    end.

maybe_create_vtep_addr6(Pid, VTEPName, VTEPNameStr, VTEPIP6) ->
    case {application:get_env(dcos_overlay, enable_ipv6, true), VTEPIP6} of
        {_, undefined} ->
            ok;
        {false, _} ->
            ?LOG_NOTICE("Overlay network is disabled [ipv6], ~s => ~p",
                [VTEPName, VTEPIP6]),
            ok;
        _ ->
            ensure_vtep_addr6_created(Pid, VTEPName, VTEPNameStr, VTEPIP6)
    end.

ensure_vtep_addr6_created(Pid, VTEPName, VTEPNameStr, VTEPIP6) ->
    case try_enable_ipv6(VTEPName) of
        ok ->
            {ParsedVTEPIP6, PrefixLen6} = parse_subnet(VTEPIP6),
            case dcos_overlay_netlink:ipaddr_replace(
                   Pid, inet6, ParsedVTEPIP6, PrefixLen6, VTEPNameStr) of
                {ok, _} ->
                    ?LOG_NOTICE(
                        "Overlay VTEP address was configured [ipv6], ~s => ~p",
                        [VTEPNameStr, VTEPIP6]),
                    ok;
                {error, Error}  ->
                    ?LOG_ERROR(
                        "Failed to replace address ~p for VTEP ~s due to ~p",
                        [VTEPIP6, VTEPNameStr, Error]),
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

try_enable_ipv6(IfName) ->
    Opt = <<"net.ipv6.conf.", IfName/binary, ".disable_ipv6=0">>,
    case dcos_net_utils:system([<<"/sbin/sysctl">>, <<"-w">>, Opt]) of
        {ok, _} ->
            ok;
        {error, Error} ->
            ?LOG_ERROR(
                "Couldn't enable IPv6 on ~s interface due to ~p",
                [IfName, Error]),
            {error, Error}
    end.

maybe_add_ip_rule(
  Pid, #{<<"info">> := #{<<"subnet">> := Subnet},
         <<"backend">> := #{<<"vxlan">> := #{<<"vtep_name">> := VTEPName}}}) ->
    case dcos_overlay_netlink:iprule_show(Pid, inet) of
        {ok, Rules} ->
            ensure_ip_rule_exists(Pid, Rules, Subnet, VTEPName);
        {error, Error} ->
            ?LOG_ERROR("Failed to get IP rules due to ~p", [Error]),
            {error, Error}
    end;
maybe_add_ip_rule(_Pid, _Overlay) ->
    ok.

ensure_ip_rule_exists(Pid, Rules, Subnet, VTEPName) ->
    {ParsedSubnetIP, PrefixLen} = parse_subnet(Subnet),
    Rule = dcos_overlay_netlink:make_iprule(
               inet, ParsedSubnetIP, PrefixLen, ?TABLE),
    case dcos_overlay_netlink:is_iprule_present(Rules, Rule) of
        false ->
            case dcos_overlay_netlink:iprule_add(
                     Pid, inet, ParsedSubnetIP, PrefixLen, ?TABLE) of
                {ok, _} ->
                    ?LOG_NOTICE(
                        "Overlay routing policy was added, ~s => ~p",
                        [VTEPName, #{overlaySubnet => Subnet}]),
                    ok;
                {error, Error} ->
                    ?LOG_ERROR(
                        "Failed to add IP rule for subnet ~p and VTEP ~p "
                        "due to ~p",
                        [Subnet, VTEPName, Error]),
                    {error, Error}
            end;
        true -> ok
    end.

maybe_add_overlay_to_lashup(Overlay, AgentIP) ->
    #{<<"info">> := OverlayInfo} = Overlay,
    #{<<"backend">> := #{<<"vxlan">> := VXLan}} = Overlay,
    AgentSubnet = mget(<<"subnet">>, Overlay),
    AgentSubnet6 = mget(<<"subnet6">>, Overlay),
    OverlaySubnet = mget(<<"subnet">>, OverlayInfo),
    OverlaySubnet6 = mget(<<"subnet6">>, OverlayInfo),
    VTEPIPStr = mget(<<"vtep_ip">>, VXLan),
    VTEPIP6Str = mget(<<"vtep_ip6">>, VXLan),
    VTEPMac = mget(<<"vtep_mac">>, VXLan),
    VTEPName = mget(<<"vtep_name">>, VXLan),
    case maybe_add_overlay_to_lashup(VTEPName, VTEPIPStr, VTEPMac, AgentSubnet,
             OverlaySubnet, AgentIP) of
        ok ->
            case maybe_add_overlay_to_lashup(VTEPName, VTEPIP6Str, VTEPMac,
                     AgentSubnet6, OverlaySubnet6, AgentIP) of
                ok -> ok;
                {error, Error} ->
                    ?LOG_ERROR(
                        "Failed to add IPv6 overlay ~p to Lashup due to ~p",
                        [Overlay, Error]),
                    {error, Error}
            end;
        {error, Error} ->
            ?LOG_ERROR(
                "Failed to add IP overlay ~p to Lashup due to ~p",
                [Overlay, Error]),
            {error, Error}
    end.

maybe_add_overlay_to_lashup(
  _VTEPName, _VTEPIPStr, _VTEPMac, _AgentSubnet, undefined, _AgentIP) ->
    ok;
maybe_add_overlay_to_lashup(
  _VTEPName, undefined, _VTEPMac, _AgentSubnet, _OverlaySubnet, _AgentIP) ->
    ok;
maybe_add_overlay_to_lashup(
  VTEPName, VTEPIPStr, VTEPMac, AgentSubnet, OverlaySubnet, AgentIP) ->
    ParsedSubnet = parse_subnet(OverlaySubnet),
    Key = [navstar, overlay, ParsedSubnet],
    LashupValue = lashup_kv:value(Key),
    case check_subnet(VTEPIPStr, VTEPMac, AgentSubnet, AgentIP, LashupValue) of
        ok -> ok;
        Updates ->
            case lashup_kv:request_op(Key, {update, [Updates]}) of
                {ok, _} ->
                    Info = #{ip => VTEPIPStr,
                             mac => VTEPMac,
                             agentSubnet => AgentSubnet,
                             overlaySubnet => OverlaySubnet},
                    ?LOG_NOTICE("Overlay network was added, ~s => ~p",
                        [VTEPName, Info]),
                    ok;
                {error, Error} ->
                    ?LOG_ERROR(
                        "Failed to update data in Lashup for ~s due to ~p",
                        [VTEPName, Error]),
                    {error, Error}
            end
    end.

-type prefix_len() :: 0..32 | 0..128.
-spec(parse_subnet(Subnet :: binary()) -> {inet:ip_address(), prefix_len()}).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 128,
    {IP, PrefixLen}.

check_subnet(VTEPIPStr, VTEPMac, AgentSubnet, AgentIP, LashupValue) ->
    ParsedSubnet = parse_subnet(AgentSubnet),
    ParsedVTEPMac = parse_vtep_mac(VTEPMac),
    ParsedVTEPIP = parse_subnet(VTEPIPStr),

    Changed = overlay_changed(
        ParsedVTEPIP, ParsedVTEPMac, AgentIP, ParsedSubnet, LashupValue),
    case Changed of
        true ->
            update_overlay_op(
                ParsedVTEPIP, ParsedVTEPMac, AgentIP, ParsedSubnet);
        false ->
            ok
    end.

parse_vtep_mac(MAC) ->
    MACComponents = binary:split(MAC, <<":">>, [global]),
    lists:map(
        fun (Component) ->
                binary_to_integer(Component, 16)
        end,
        MACComponents).

overlay_changed(VTEPIP, VTEPMac, AgentIP, Subnet, LashupValue) ->
    case lists:keyfind({VTEPIP, riak_dt_map}, 1, LashupValue) of
        {{VTEPIP, riak_dt_map}, Value} ->
            ExpectedValue = [
                {{agent_ip, riak_dt_lwwreg}, AgentIP},
                {{mac, riak_dt_lwwreg}, VTEPMac},
                {{subnet, riak_dt_lwwreg}, Subnet}
            ],
            case lists:sort(Value) of
                ExpectedValue -> false;
                _ -> true
            end;
        false -> true
    end.

update_overlay_op(VTEPIP, VTEPMac, AgentIP, Subnet) ->
    Now = erlang:system_time(nano_seconds),
    {update,
        {VTEPIP, riak_dt_map},
        {update, [
            {update, {mac, riak_dt_lwwreg}, {assign, VTEPMac, Now}},
            {update, {agent_ip, riak_dt_lwwreg}, {assign, AgentIP, Now}},
            {update, {subnet, riak_dt_lwwreg}, {assign, Subnet, Now}}
            ]
        }
    }.

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(init_metrics() -> ok).
init_metrics() ->
    prometheus_summary:new([
        {registry, overlay},
        {name, poll_duration_seconds},
        {duration_unit, seconds},
        {help, "The time spent polling local Mesos overlays."}]),
    prometheus_counter:new([
        {registry, overlay},
        {name, poll_errors_total},
        {help, "Total number of errors while polling local Mesos overlays."}]),
    prometheus_gauge:new([
        {registry, overlay},
        {name, networks_configured},
        {help, "The number of overlay networks configured."}]),
    prometheus_counter:new([
        {registry, overlay},
        {name, network_configuration_failures_total},
        {help,
            "Total number of failures while configuring overlay networks."}]).

-ifdef(TEST).

match_vtep_link_test() ->
    VNI = 1024,
    VTEPIP = <<"44.128.0.1/20">>,
    VTEPMAC = <<"70:b3:d5:80:00:01">>,
    VTEPMAC2 = <<"70:b3:d5:80:00:02">>,
    VTEPNAME = <<"vtep1024">>,
    VTEPDataFilename = "apps/dcos_overlay/testdata/vtep_link.data",
    {ok, [RtnetLinkInfo]} = file:consult(VTEPDataFilename),
    [#rtnetlink{type=newlink, msg=Msg}] = RtnetLinkInfo,
    {unspec, arphrd_ether, _, _, _, LinkInfo} = Msg,
    VXLan = #{
        <<"vni">> => VNI,
        <<"vtep_ip">> => VTEPIP,
        <<"vtep_mac">> => VTEPMAC,
        <<"vtep_name">> => VTEPNAME
    },
    ?assertEqual(true, match_vtep_link(VXLan, LinkInfo)),

    VXLan2 = VXLan#{<<"vtep_mac">> := VTEPMAC2},
    ?assertEqual(false, match_vtep_link(VXLan2, LinkInfo)).

overlay_changed_test() ->
    VTEPIP = {{44, 128, 0, 1}, 20},
    VTEPMac = [112, 179, 213, 128, 0, 1],
    AgentIP = {172, 17, 0, 2},
    Subnet = {{9, 0, 0, 0}, 24},
    LashupValue = [],
    ?assert(overlay_changed(VTEPIP, VTEPMac, AgentIP, Subnet, LashupValue)),
    LashupValue2 = [
         {{{{44, 128, 0, 1}, 20}, riak_dt_map},
             [{{subnet, riak_dt_lwwreg}, {{9, 0, 0, 0}, 24}},
              {{mac, riak_dt_lwwreg}, [112, 179, 213, 128, 0, 1]},
              {{agent_ip, riak_dt_lwwreg}, {172, 17, 0, 2}}]}
    ],
    ?assertNot(overlay_changed(VTEPIP, VTEPMac, AgentIP, Subnet, LashupValue2)),
    LashupValue3 = [
         {{{{44, 128, 0, 1}, 20}, riak_dt_map},
             [{{subnet, riak_dt_lwwreg}, {{9, 0, 1, 0}, 24}},
              {{mac, riak_dt_lwwreg}, [112, 179, 213, 128, 0, 1]},
              {{agent_ip, riak_dt_lwwreg}, {172, 17, 0, 2}}]}
    ],
    ?assert(overlay_changed(VTEPIP, VTEPMac, AgentIP, Subnet, LashupValue3)),
    LashupValue4 = [
         {{{{44, 128, 0, 1}, 20}, riak_dt_map},
             [{{subnet, riak_dt_lwwreg}, {{9, 0, 0, 0}, 24}},
              {{mac, riak_dt_lwwreg}, [112, 179, 213, 128, 0, 2]},
              {{agent_ip, riak_dt_lwwreg}, {172, 17, 0, 2}}]}
    ],
    ?assert(overlay_changed(VTEPIP, VTEPMac, AgentIP, Subnet, LashupValue4)),
    LashupValue5 = [
         {{{{44, 128, 0, 1}, 20}, riak_dt_map},
             [{{subnet, riak_dt_lwwreg}, {{9, 0, 0, 0}, 24}},
              {{mac, riak_dt_lwwreg}, [112, 179, 213, 128, 0, 1]},
              {{agent_ip, riak_dt_lwwreg}, {172, 17, 0, 3}}]}
    ],
    ?assert(overlay_changed(VTEPIP, VTEPMac, AgentIP, Subnet, LashupValue5)),
    LashupValue6 = [
         {{{{44, 128, 0, 2}, 20}, riak_dt_map},
             [{{subnet, riak_dt_lwwreg}, {{9, 0, 0, 0}, 24}},
              {{mac, riak_dt_lwwreg}, [112, 179, 213, 128, 0, 1]},
              {{agent_ip, riak_dt_lwwreg}, {172, 17, 0, 2}}]}
    ],
    ?assert(overlay_changed(VTEPIP, VTEPMac, AgentIP, Subnet, LashupValue6)).

-endif.
