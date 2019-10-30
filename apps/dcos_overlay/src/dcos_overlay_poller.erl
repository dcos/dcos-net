%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 9:27 PM
%%%-------------------------------------------------------------------
-module(dcos_overlay_poller).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0, ip/0, overlays/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(MIN_POLL_PERIOD, 30000). %% 30 secs
-define(MAX_POLL_PERIOD, 120000). %% 120 secs
-define(VXLAN_UDP_PORT, 64000).

-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("gen_netlink/include/netlink.hrl").

-define(TABLE, 42).

-record(state, {
    known_overlays = ordsets:new(),
    ip = undefined :: undefined | inet:ip4_address(),
    poll_period = ?MIN_POLL_PERIOD :: integer(),
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
    self() ! init,
    {ok, []}.

handle_call(ip, _From, State = #state{ip = IP}) ->
    {reply, IP, State};
handle_call(overlays, _From, State = #state{known_overlays = KnownOverlays}) ->
    {reply, KnownOverlays, State};
handle_call(Request, _From, State) ->
    lager:warning("Unexpected request: ~p", [Request]),
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, []) ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    timer:send_after(0, poll),
    {noreply, #state{netlink = Pid}};
handle_info(poll, State0) ->
    State1 =
        case dcos_net_mesos:poll("/overlay-agent/overlay") of
            {error, Reason} ->
                lager:warning("Overlay Poller could not poll: ~p~n", [Reason]),
                State0#state{poll_period = ?MIN_POLL_PERIOD};
            {ok, Data} ->
                NewState = parse_response(State0, Data),
                NewPollPeriod = update_poll_period(NewState#state.poll_period),
                NewState#state{poll_period = NewPollPeriod}
        end,
    timer:send_after(State1#state.poll_period, poll),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

update_poll_period(OldPollPeriod) when OldPollPeriod*2 =< ?MAX_POLL_PERIOD ->
    OldPollPeriod*2;
update_poll_period(_) ->
    ?MAX_POLL_PERIOD.

parse_response(State0 = #state{known_overlays = KnownOverlays}, AgentInfo) ->
    IP0 = maps:get(<<"ip">>, AgentInfo),
    IP1 = process_ip(IP0),
    State1 = State0#state{ip = IP1},
    Overlays = maps:get(<<"overlays">>, AgentInfo, []),
    NewOverlays = Overlays -- KnownOverlays,
    lists:foldl(fun add_overlay/2, State1, NewOverlays).

process_ip(IPBin0) ->
    [IPBin1|_MaybePort] = binary:split(IPBin0, <<":">>),
    IPStr = binary_to_list(IPBin1),
    {ok, IP} = inet:parse_ipv4_address(IPStr),
    IP.

add_overlay(Overlay=#{<<"backend">> := #{<<"vxlan">> := VxLan},
                      <<"state">> := #{<<"status">> := <<"STATUS_OK">>}},
            State=#state{known_overlays=KnownOverlays}) ->
    lager:notice("Configuring new overlay network, ~p", [VxLan]),
    config_overlay(Overlay, State),
    maybe_add_overlay_to_lashup(Overlay, State),
    State#state{known_overlays=[Overlay | KnownOverlays]};
add_overlay(Overlay, State) ->
    lager:warning("Bad overlay network was skipped, ~p", [Overlay]),
    State.

config_overlay(Overlay, State) ->
    maybe_create_vtep(Overlay, State),
    maybe_add_ip_rule(Overlay, State).

mget(Key, Map) ->
    maps:get(Key, Map, undefined).

maybe_create_vtep(#{<<"backend">> := Backend}, #state{netlink = Pid}) ->
    #{<<"vxlan">> := VXLan} = Backend,
    maybe_create_vtep_link(Pid, VXLan),
    create_vtep_addr(Pid, VXLan).

maybe_create_vtep_link(Pid, VXLan) ->
    #{<<"vtep_name">> := VTEPName} = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    case check_vtep_link(Pid, VXLan) of
        false ->
            lager:info("Overlay VTEP link will be created, ~s", [VTEPName]),
            create_vtep_link(Pid, VXLan);
        {true, true} ->
            lager:info("Overlay VTEP link is up-to-date, ~s", [VTEPName]);
        {true, false} ->
            lager:info("Overlay VTEP link is not up-to-date, and will be recreated, ~s", [VTEPName]),
            dcos_overlay_netlink:iplink_delete(Pid, VTEPNameStr),
            lager:notice("Overlay VTEP link was removed, ~s", [VTEPName]),
            create_vtep_link(Pid, VXLan)
    end.

check_vtep_link(Pid, VXLan) ->
    #{<<"vtep_name">> := VTEPName} = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    case dcos_overlay_netlink:iplink_show(Pid, VTEPNameStr) of
        {ok, [#rtnetlink{type=newlink, msg=Msg}]} ->
            {unspec, arphrd_ether, _, _, _, LinkInfo} = Msg,
            Match = match_vtep_link(VXLan, LinkInfo),
            {true, Match};
        {error, enodev, _ErrorMsg} ->
            lager:info("Overlay VTEP link does not exist, ~s", [VTEPName]),
            false
    end.

match_vtep_link(VXLan, Link) ->
    #{ <<"vni">> := VNI,
       <<"vtep_mac">> := VTEPMAC
    } = VXLan,
    Expected =
        [{address, binary:list_to_bin(parse_vtep_mac(VTEPMAC))},
         {linkinfo, [{kind, "vxlan"}, {data, [{id, VNI}, {port, ?VXLAN_UDP_PORT}]}]}],
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
    #{ <<"vni">> := VNI,
       <<"vtep_mac">> := VTEPMAC,
       <<"vtep_name">> := VTEPName
    } = VXLan,
    VTEPMTU = mget(<<"vtep_mtu">>, VXLan),
    VTEPNameStr = binary_to_list(VTEPName),
    ParsedVTEPMAC = list_to_tuple(parse_vtep_mac(VTEPMAC)),
    VTEPAttr = [{mtu, VTEPMTU} || is_integer(VTEPMTU)],
    dcos_overlay_netlink:iplink_add(Pid, VTEPNameStr, "vxlan", VNI, ?VXLAN_UDP_PORT, VTEPAttr),
    {ok, _} = dcos_overlay_netlink:iplink_set(Pid, ParsedVTEPMAC, VTEPNameStr),
    Info = #{vni => VNI, mac => VTEPMAC, attr => VTEPAttr},
    lager:notice("Overlay VTEP link was configured, ~s => ~p", [VTEPName, Info]).

create_vtep_addr(Pid, VXLan) ->
    #{ <<"vtep_ip">> := VTEPIP,
       <<"vtep_name">> := VTEPName
    } = VXLan,
    VTEPIP6 = mget(<<"vtep_ip6">>, VXLan),
    VTEPNameStr = binary_to_list(VTEPName),
    {ParsedVTEPIP, PrefixLen} = parse_subnet(VTEPIP),
    {ok, _} = dcos_overlay_netlink:ipaddr_replace(Pid, inet, ParsedVTEPIP, PrefixLen, VTEPNameStr),
    lager:notice("Overlay VTEP address was configured, ~s => ~p", [VTEPName, VTEPIP]),
    case {application:get_env(dcos_overlay, enable_ipv6, true), VTEPIP6} of
      {_, undefined} ->
          ok;
      {false, _} ->
          lager:notice("Overlay network is disabled [ipv6], ~s => ~p", [VTEPName, VTEPIP6]);
      _ ->
          ok = try_enable_ipv6(VTEPName),
          {ParsedVTEPIP6, PrefixLen6} = parse_subnet(VTEPIP6),
          {ok, _} = dcos_overlay_netlink:ipaddr_replace(Pid, inet6, ParsedVTEPIP6, PrefixLen6, VTEPNameStr),
          lager:notice("Overlay VTEP address was configured [ipv6], ~s => ~p", [VTEPName, VTEPIP6])
    end.


try_enable_ipv6(IfName) ->
    Opt = <<"net.ipv6.conf.", IfName/binary, ".disable_ipv6=0">>,
    case dcos_net_utils:system([<<"/sbin/sysctl">>, <<"-w">>, Opt]) of
        {ok, _} ->
            ok;
        {error, Error} ->
            lager:error(
                "Couldn't enable IPv6 on ~s interface due to ~p",
                [IfName, Error])
    end.

maybe_add_ip_rule(#{<<"info">> := #{<<"subnet">> := Subnet},
                    <<"backend">> := #{<<"vxlan">> := #{<<"vtep_name">> := VTEPName}}},
                  #state{netlink = Pid}) ->
    {ParsedSubnetIP, PrefixLen} = parse_subnet(Subnet),
    {ok, Rules} = dcos_overlay_netlink:iprule_show(Pid, inet),
    Rule = dcos_overlay_netlink:make_iprule(inet, ParsedSubnetIP, PrefixLen, ?TABLE),
    case dcos_overlay_netlink:is_iprule_present(Rules, Rule) of
        false ->
            {ok, _} = dcos_overlay_netlink:iprule_add(Pid, inet, ParsedSubnetIP, PrefixLen, ?TABLE),
            lager:notice(
                "Overlay routing policy was added, ~s => ~p",
                [VTEPName, #{overlaySubnet => Subnet}]);
        _ ->
            ok
    end;
maybe_add_ip_rule(_Overlay, _State) ->
    ok.

maybe_add_overlay_to_lashup(Overlay, State) ->
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
    maybe_add_overlay_to_lashup(VTEPName, VTEPIPStr, VTEPMac, AgentSubnet, OverlaySubnet, State),
    maybe_add_overlay_to_lashup(VTEPName, VTEPIP6Str, VTEPMac, AgentSubnet6, OverlaySubnet6, State).

maybe_add_overlay_to_lashup(_VTEPName, _VTEPIPStr, _VTEPMac, _AgentSubnet, undefined, _State) ->
    ok;
maybe_add_overlay_to_lashup(_VTEPName, undefined, _VTEPMac, _AgentSubnet, _OverlaySubnet, _State) ->
    ok;
maybe_add_overlay_to_lashup(VTEPName, VTEPIPStr, VTEPMac, AgentSubnet, OverlaySubnet, State) ->
    ParsedSubnet = parse_subnet(OverlaySubnet),
    Key = [navstar, overlay, ParsedSubnet],
    LashupValue = lashup_kv:value(Key),
    case check_subnet(VTEPIPStr, VTEPMac, AgentSubnet, LashupValue, State) of
        ok -> ok;
        Updates ->
            {ok, _} = lashup_kv:request_op(Key, {update, [Updates]}),
            Info = #{ip => VTEPIPStr, mac => VTEPMac,
                     agentSubnet => AgentSubnet, overlaySubnet => OverlaySubnet},
            lager:notice("Overlay network was added, ~s => ~p", [VTEPName, Info])
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

check_subnet(VTEPIPStr, VTEPMac, AgentSubnet, LashupValue,
  _State = #state{ip = AgentIP}) ->

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
        fun(Component) ->
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

-ifdef(TEST).

match_vtep_link_test() ->
    VNI = 1024,
    VTEPIP = <<"44.128.0.1/20">>,
    VTEPMAC = <<"70:b3:d5:80:00:01">>,
    VTEPMAC2 = <<"70:b3:d5:80:00:02">>,
    VTEPNAME = <<"vtep1024">>,
    {ok, [RtnetLinkInfo]} = file:consult("apps/dcos_overlay/testdata/vtep_link.data"),
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
