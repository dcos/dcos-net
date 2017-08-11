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

-include("dcos_overlay.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").
-include_lib("gen_netlink/include/netlink.hrl").

-define(TABLE, 42).
-define(MASTERS_KEY, {masters, riak_dt_orswot}).

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

netlink() ->
    gen_server:call(?SERVER, netlink).

%% @doc Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    timer:send_after(0, poll),
    {ok, #state{netlink = Pid}}.

handle_call(ip, _From, State = #state{ip = IP}) ->
    {reply, IP, State};
handle_call(overlays, _From, State = #state{known_overlays = KnownOverlays}) ->
    {reply, KnownOverlays, State};
handle_call(_Request, _From, State) ->
    lager:warning("Unexpected request: ~p", [_Request]),
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(poll, State0) ->
    State1 =
        case poll(State0) of
            {error, Reason} ->
                lager:warning("Overlay Poller could not poll: ~p~n", [Reason]),
                State0#state{poll_period = ?MIN_POLL_PERIOD};
            {ok, NewState} ->
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

scheme() ->
    case os:getenv("MESOS_STATE_SSL_ENABLED") of
        "true" ->
            "https";
        _ ->
            "http"
    end.

update_poll_period(OldPollPeriod) when OldPollPeriod*2 =< ?MAX_POLL_PERIOD ->
    OldPollPeriod*2;
update_poll_period(_) ->
    ?MAX_POLL_PERIOD.

poll(State0) ->
    Options = [
        {ssl, [{server_name_indication, disable}]},
        {timeout, application:get_env(?APP, timeout, ?DEFAULT_TIMEOUT)},
        {connect_timeout, application:get_env(?APP, connect_timeout, ?DEFAULT_CONNECT_TIMEOUT)}
    ],
    IP = inet:ntoa(mesos_state:ip()),
    Masters = masters(),
    BaseURI =
        case ordsets:is_element(node(), Masters) of
            true ->
                scheme() ++ "://~s:5050/overlay-agent/overlay";
            false ->
                scheme() ++ "://~s:5051/overlay-agent/overlay"
        end,

    URI = lists:flatten(io_lib:format(BaseURI, [IP])),
    Headers = [{"Accept", "application/x-protobuf"}, {"node", atom_to_list(node())}],
    Response = httpc:request(get, {URI, Headers}, Options, [{body_format, binary}]),
    handle_response(State0, Response).

handle_response(_State0, {error, Reason}) ->
    {error, Reason};
handle_response(State0, {ok, {_StatusLine = {_HTTPVersion, 200 = _StatusCode, _ReasonPhrase}, _Headers, Body}}) ->
    parse_response(State0, Body);
handle_response(_State0, {ok, {StatusLine, _Headers, _Body}}) ->
    {error, StatusLine}.

parse_response(State0 = #state{known_overlays = KnownOverlays}, Body) ->
    AgentInfo = #mesos_state_agentinfo{} = mesos_state_overlay_pb:decode_msg(Body, mesos_state_agentinfo),
    #mesos_state_agentinfo{ip = IP0} = AgentInfo,
    IP1 = process_ip(IP0),
    State1 = State0#state{ip = IP1},
    Overlays = ordsets:from_list(AgentInfo#mesos_state_agentinfo.overlays),
    NewOverlays = ordsets:subtract(Overlays, KnownOverlays),
    State2 = lists:foldl(fun add_overlay/2, State1, NewOverlays),
    {ok, State2}.

process_ip(IPBin0) ->
    [IPBin1|_MaybePort] = binary:split(IPBin0, <<":">>),
    IPStr = binary_to_list(IPBin1),
    {ok, IP} = inet:parse_ipv4_address(IPStr),
    IP.


add_overlay(
  Overlay = #mesos_state_agentoverlayinfo{state = #'mesos_state_agentoverlayinfo.state'{status = 'STATUS_OK'}},
  State0 = #state{known_overlays = KnownOverlays0}) ->
    KnownOverlays1 = ordsets:add_element(Overlay, KnownOverlays0),
    State1 = State0#state{known_overlays = KnownOverlays1},
    config_overlay(Overlay, State1),
    maybe_add_overlay_to_lashup(Overlay, State1),
    State1;
add_overlay(Overlay, State) ->
    lager:warning("Overlay not okay: ~p", [Overlay]),
    State.

config_overlay(Overlay, State) ->
    maybe_create_vtep(Overlay, State),
    maybe_add_ip_rule(Overlay, State).

maybe_create_vtep(_Overlay = #mesos_state_agentoverlayinfo{backend = Backend},
  #state{netlink = Pid}) ->
    #mesos_state_backendinfo{vxlan = VXLan} = Backend,
    #mesos_state_vxlaninfo{
        vni = VNI,
        vtep_ip = VTEPIP,
        vtep_ip6 = VTEPIP6,
        vtep_mac = VTEPMAC,
        vtep_name = VTEPName
    } = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    ParsedVTEPMAC = list_to_tuple(parse_vtep_mac(VTEPMAC)),
    {ParsedVTEPIP, PrefixLen} = parse_subnet(VTEPIP),
    {ParsedVTEPIP6, PrefixLen6} = parse_subnet(VTEPIP6),
    dcos_overlay_netlink:iplink_add(Pid, VTEPNameStr, "vxlan", VNI, 64000),
    {ok, _} = dcos_overlay_netlink:iplink_set(Pid, ParsedVTEPMAC, VTEPNameStr),
    {ok, _} = dcos_overlay_netlink:ipaddr_replace(Pid, inet, ParsedVTEPIP, PrefixLen, VTEPNameStr),
    {ok, _} = dcos_overlay_netlink:ipaddr_replace(Pid, inet6, ParsedVTEPIP6, PrefixLen6, VTEPNameStr).

maybe_add_ip_rule(_Overlay = #mesos_state_agentoverlayinfo{info = #mesos_state_overlayinfo{subnet = Subnet}},
 #state{netlink = Pid}) ->
    {ParsedSubnetIP, PrefixLen} = parse_subnet(Subnet),
    {ok, Rules} = dcos_overlay_netlink:iprule_show(Pid, inet),
    Rule = dcos_overlay_netlink:make_iprule(inet, ParsedSubnetIP, PrefixLen, ?TABLE),
    case dcos_overlay_netlink:is_iprule_present(Rules, Rule) of
        false ->
            {ok, _} = dcos_overlay_netlink:iprule_add(Pid, inet, ParsedSubnetIP, PrefixLen, ?TABLE);
        _ ->
            ok
    end.

%% Always return an ordered set of masters
-spec(masters() -> [node()]).
masters() ->
    Masters = lashup_kv:value([masters]),
    case orddict:find(?MASTERS_KEY, Masters) of
        error ->
            [];
        {ok, Value} ->
            ordsets:from_list(Value)
    end.

maybe_add_overlay_to_lashup(Overlay, State) ->
    #mesos_state_agentoverlayinfo{
      backend = #mesos_state_backendinfo{vxlan = VXLan},
      subnet = AgentSubnet,
      subnet6 = AgentSubnet6,
      info = #mesos_state_overlayinfo{
        subnet = OverlaySubnet,
        subnet6 = OverlaySubnet6
      }
    } = Overlay,
    #mesos_state_vxlaninfo{
        vtep_ip = VTEPIPStr,
        vtep_ip6 = VTEPIP6Str,
        vtep_mac = VTEPMac
    } = VXLan,
    lager:warning("~p, ~p, ~p", [VTEPIPStr, VTEPIP6Str, VTEPMac]),
    maybe_add_overlay_to_lashup(VTEPIPStr, VTEPMac, AgentSubnet, OverlaySubnet, State),
    maybe_add_overlay_to_lashup(VTEPIP6Str, VTEPMac, AgentSubnet6, OverlaySubnet6, State).

maybe_add_overlay_to_lashup(_VTEPIPStr, _VTEPMac, _AgentSubnet, undefined, _State) ->
    ok;
maybe_add_overlay_to_lashup(VTEPIPStr, VTEPMac, AgentSubnet, OverlaySubnet, State) ->
    ParsedSubnet = parse_subnet(OverlaySubnet),
    Key = [navstar, overlay, ParsedSubnet],
    LashupValue = lashup_kv:value(Key),
    case check_subnet(VTEPIPStr, VTEPMac, AgentSubnet, LashupValue, State) of
        ok ->
            ok;
        Updates ->
            lager:info("Overlay poller updating lashup"),
            {ok, _} = lashup_kv:request_op(Key, {update, [Updates]})
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

-ifdef(TEST).

deserialize_overlay_test() ->
    DataDir = code:priv_dir(dcos_overlay),
    OverlayFilename = filename:join(DataDir, "overlay.bindata.pb"),
    {ok, OverlayData} = file:read_file(OverlayFilename),
    Msg = mesos_state_overlay_pb:decode_msg(OverlayData, mesos_state_agentinfo),
    ?assertEqual(<<"10.0.0.160:5051">>, Msg#mesos_state_agentinfo.ip).

-endif.
