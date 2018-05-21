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
-export([
    ip/0,
    overlays/0,
    start_link/0,
    subnet2name/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-export_type([subnet/0]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(MIN_POLL_PERIOD, 30000). %% 30 secs
-define(MAX_POLL_PERIOD, 120000). %% 120 secs

-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("gen_netlink/include/netlink.hrl").

-define(TABLE, 42).

-record(state, {
    known_overlays = ordsets:new(),
    ip = undefined :: undefined | inet:ip4_address(),
    poll_period = ?MIN_POLL_PERIOD :: integer(),
    netlink :: undefined | pid()
}).

-type subnet() :: {inet:ip_address(), 0..32 | 0..128}.

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
    try
        ets:new(?MODULE, [named_table, public, {read_concurrency, true}])
    catch error:badarg ->
        ?MODULE
    end,
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec subnet2name(subnet()) -> undefined | binary().
subnet2name(Subnet) ->
    try ets:lookup(?MODULE, Subnet) of
        [{Subnet, Name}] -> Name;
        [] -> undefined
    catch error:badarg ->
        undefined
    end.

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
        case poll() of
            {error, Reason} ->
                ok = m_notify({poller, failures}, {inc, 1}, counter),
                lager:warning("Overlay Poller could not poll: ~p~n", [Reason]),
                State0#state{poll_period = ?MIN_POLL_PERIOD};
            {ok, Data} ->
                ok = m_notify({poller, responses}, {inc, 1}, counter),
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

-spec(update_poll_period(pos_integer()) -> pos_integer()).
update_poll_period(OldPollPeriod) when OldPollPeriod*2 =< ?MAX_POLL_PERIOD ->
    OldPollPeriod*2;
update_poll_period(_) ->
    ?MAX_POLL_PERIOD.

-spec(poll() ->
    {ok, jiffy:json_term()} | {error, Reason :: term()}).
poll() ->
    Begin = erlang:monotonic_time(millisecond),
    try
        dcos_net_mesos:poll("/overlay-agent/overlay")
    after
        Ms = erlang:monotonic_time(millisecond) - Begin,
        ok = m_notify({poller, response_ms}, Ms, gauge)
    end.

parse_response(State0 = #state{known_overlays = KnownOverlays}, AgentInfo) ->
    IP0 = maps:get(<<"ip">>, AgentInfo),
    IP1 = process_ip(IP0),
    State1 = State0#state{ip = IP1},
    Overlays = maps:get(<<"overlays">>, AgentInfo, []),
    ok = m_notify(networks, length(Overlays), gauge),
    NewOverlays = Overlays -- KnownOverlays,
    lists:foldl(fun add_overlay/2, State1, NewOverlays).

process_ip(IPBin0) ->
    [IPBin1|_MaybePort] = binary:split(IPBin0, <<":">>),
    IPStr = binary_to_list(IPBin1),
    {ok, IP} = inet:parse_ipv4_address(IPStr),
    IP.

add_overlay(Overlay=#{<<"state">> := #{<<"status">> := <<"STATUS_OK">>}},
            State=#state{known_overlays=KnownOverlays}) ->
    config_overlay(Overlay, State),
    maybe_add_overlay_to_lashup(Overlay, State),
    State#state{known_overlays=[Overlay | KnownOverlays]};
add_overlay(Overlay, State) ->
    lager:warning("Overlay not okay: ~p", [Overlay]),
    State.

config_overlay(Overlay, State) ->
    maybe_create_vtep(Overlay, State),
    maybe_add_ip_rule(Overlay, State).

mget(Key, Map) ->
    maps:get(Key, Map, undefined).

maybe_create_vtep(#{<<"backend">> := Backend}, #state{netlink = Pid}) ->
    #{<<"vxlan">> := VXLan} = Backend,
    #{ <<"vni">> := VNI,
       <<"vtep_ip">> := VTEPIP,
       <<"vtep_mac">> := VTEPMAC,
       <<"vtep_name">> := VTEPName
    } = VXLan,
    VTEPIP6 = mget(<<"vtep_ip6">>, VXLan),
    VTEPMTU = mget(<<"vtep_mtu">>, VXLan),
    VTEPNameStr = binary_to_list(VTEPName),
    ParsedVTEPMAC = list_to_tuple(parse_vtep_mac(VTEPMAC)),
    {ParsedVTEPIP, PrefixLen} = parse_subnet(VTEPIP),
    VTEPAttr = [{mtu, VTEPMTU} || is_integer(VTEPMTU)],
    dcos_overlay_netlink:iplink_add(Pid, VTEPNameStr, "vxlan", VNI, 64000, VTEPAttr),
    {ok, _} = dcos_overlay_netlink:iplink_set(Pid, ParsedVTEPMAC, VTEPNameStr),
    {ok, _} = dcos_overlay_netlink:ipaddr_replace(Pid, inet, ParsedVTEPIP, PrefixLen, VTEPNameStr),
    case {application:get_env(dcos_overlay, enable_ipv6, true), VTEPIP6} of
      {false, _} ->
          ok;
      {_, undefined} ->
          ok;
      _ ->
          ok = try_enable_ipv6(VTEPNameStr),
          {ParsedVTEPIP6, PrefixLen6} = parse_subnet(VTEPIP6),
          {ok, _} = dcos_overlay_netlink:ipaddr_replace(Pid, inet6, ParsedVTEPIP6, PrefixLen6, VTEPNameStr)
    end.

try_enable_ipv6(IfName) ->
    Var = lists:flatten(io_lib:format("net.ipv6.conf.~s.disable_ipv6=0", [IfName])),
    Cmd = lists:flatten(io_lib:format("/sbin/sysctl -w ~s", [Var])),
    Port = open_port({spawn, Cmd}, [exit_status]),
    receive
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, ExitCode}} ->
            lager:error("Couldn't enable IPv6 on ~s interface due to ~p", [IfName, ExitCode]),
            ExitCode
    end.

maybe_add_ip_rule(#{<<"info">> := #{<<"subnet">> := Subnet}}, #state{netlink = Pid}) ->
    {ParsedSubnetIP, PrefixLen} = parse_subnet(Subnet),
    {ok, Rules} = dcos_overlay_netlink:iprule_show(Pid, inet),
    Rule = dcos_overlay_netlink:make_iprule(inet, ParsedSubnetIP, PrefixLen, ?TABLE),
    case dcos_overlay_netlink:is_iprule_present(Rules, Rule) of
        false ->
            {ok, _} = dcos_overlay_netlink:iprule_add(Pid, inet, ParsedSubnetIP, PrefixLen, ?TABLE);
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
    OverlayName = mget(<<"name">>, OverlayInfo),
    OverlaySubnet = mget(<<"subnet">>, OverlayInfo),
    OverlaySubnet6 = mget(<<"subnet6">>, OverlayInfo),
    VTEPIPStr = mget(<<"vtep_ip">>, VXLan),
    VTEPIP6Str = mget(<<"vtep_ip6">>, VXLan),
    VTEPMac = mget(<<"vtep_mac">>, VXLan),
    maybe_add_overlay_to_lashup(
        VTEPIPStr, VTEPMac, AgentSubnet,
        OverlaySubnet, OverlayName, State),
    maybe_add_overlay_to_lashup(
        VTEPIP6Str, VTEPMac, AgentSubnet6,
        OverlaySubnet6, OverlayName, State).

maybe_add_overlay_to_lashup(
        _VTEPIPStr, _VTEPMac, _AgentSubnet,
        undefined, _OverlayName, _State) ->
    ok;
maybe_add_overlay_to_lashup(
        undefined, _VTEPMac, _AgentSubnet,
        _OverlaySubnet, _OverlayName, _State) ->
    ok;
maybe_add_overlay_to_lashup(
        VTEPIPStr, VTEPMac, AgentSubnet,
        OverlaySubnet, OverlayName, State) ->
    ParsedSubnet = parse_subnet(OverlaySubnet),
    ets:insert(?MODULE, {ParsedSubnet, OverlayName}),
    Key = [navstar, overlay, ParsedSubnet],
    LashupValue = lashup_kv:value(Key),
    case check_subnet(VTEPIPStr, VTEPMac, AgentSubnet, LashupValue, State) of
        ok ->
            ok;
        Updates ->
            lager:info("Overlay poller updating lashup"),
            {ok, _} = lashup_kv:request_op(Key, {update, [Updates]})
    end.

-spec(parse_subnet(Subnet :: binary()) -> subnet()).
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
    case lists:keyfind({ParsedVTEPIP, riak_dt_map}, 1, LashupValue) of
        {{ParsedVTEPIP, riak_dt_map}, _Value} ->
            ok;
        false ->
            Now = erlang:system_time(nano_seconds),
            {update,
                {ParsedVTEPIP, riak_dt_map},
                {update, [
                    {update, {mac, riak_dt_lwwreg}, {assign, ParsedVTEPMac, Now}},
                    {update, {agent_ip, riak_dt_lwwreg}, {assign, AgentIP, Now}},
                    {update, {subnet, riak_dt_lwwreg}, {assign, ParsedSubnet, Now}}
                    ]
                }
            }
    end.

parse_vtep_mac(MAC) ->
    MACComponents = binary:split(MAC, <<":">>, [global]),
    lists:map(
        fun(Component) ->
            binary_to_integer(Component, 16)
        end,
        MACComponents).

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(m_notify(Key :: atom() | {atom(), atom()},
               Value :: any(), Type :: atom()) -> ok).
m_notify({KeyA, KeyB}, Value, Type) ->
    folsom_metrics:notify({overlay, KeyA, KeyB}, Value, Type);
m_notify(Key, Value, Type) ->
    folsom_metrics:notify({overlay, Key}, Value, Type).
