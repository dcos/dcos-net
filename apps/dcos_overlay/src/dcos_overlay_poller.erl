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
-export([start_link/0, ip/0]).

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
-define(POLL_PERIOD, 30000).
-include("dcos_overlay.hrl").
-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").
-define(MASTERS_KEY, {masters, riak_dt_orswot}).


-record(state, {
    known_overlays = ordsets:new(),
    ip = undefined :: undefined | inet:ip4_address()
}).


%%%===================================================================
%%% API
%%%===================================================================

ip() ->
    gen_server:call(?SERVER, ip).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    timer:send_after(0, poll),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(ip, _From, State = #state{ip = IP}) ->
    {reply, IP, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info(poll, State0) ->
    State1 =
        case poll(State0) of
            {error, Reason} ->
                lager:warning("Overlay Poller could not poll: ~p~n", [Reason]),
                State0;
            {ok, NewState} ->
                NewState
        end,
    State2 = try_configure_overlays(State1),
    timer:send_after(?POLL_PERIOD, poll),
    {noreply, State2};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
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

poll(State0) ->
    Options = [
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
    Headers = [{"Accept", "application/x-protobuf"}],
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
    config_overlay(Overlay),
    maybe_add_overlay_to_lashup(Overlay, State1),
    State1;
add_overlay(Overlay, State) ->
    lager:warning("Overlay not okay: ~p", [Overlay]),
    State.

config_overlay(Overlay) ->
    maybe_create_vtep(Overlay),
    maybe_add_ip_rule(Overlay).

maybe_create_vtep(_Overlay = #mesos_state_agentoverlayinfo{backend = Backend}) ->
    #mesos_state_backendinfo{vxlan = VXLan} = Backend,
    #mesos_state_vxlaninfo{
        vni = VNI,
        vtep_ip = VTEPIP,
        vtep_mac = VTEPMAC,
        vtep_name = VTEPName
    } = VXLan,
    case run_command("ip link show dev ~s", [VTEPName]) of
        {ok, _Output} ->
            ok;
        {error, 1, _} ->
            {ok, _} = run_command("ip link add dev ~s type vxlan id ~B dstport 64000", [VTEPName, VNI])
    end,
    {ok, _} = run_command("ip link set ~s address ~s", [VTEPName, VTEPMAC]),
    {ok, _} = run_command("ip link set ~s up", [VTEPName]),
    case run_command("ip addr add ~s dev ~s", [VTEPIP, VTEPName]) of
        {ok, _} ->
            ok;
        {error, 2, "RTNETLINK answers: File exists\n"} ->
            ok
    end.

maybe_add_ip_rule(_Overlay = #mesos_state_agentoverlayinfo{info = #mesos_state_overlayinfo{subnet = Subnet}}) ->
    RuleStr = lists:flatten(io_lib:format("from ~s lookup 42", [Subnet])),
    {ok, Rules} = run_command("ip rule show"),
    case string:str(Rules, RuleStr) of
        0 ->
            {ok, _} = run_command("ip rule add from ~s lookup 42", [Subnet]);
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

maybe_add_overlay_to_lashup(Overlay = #mesos_state_agentoverlayinfo{info = #mesos_state_overlayinfo{subnet = Subnet}},
    State) ->
    ParsedSubnet = parse_subnet(Subnet),
    Key = [navstar, overlay, ParsedSubnet],
    LashupValue = lashup_kv:value(Key),
    Now = erlang:system_time(nano_seconds),
    case check_subnet(Overlay, State, LashupValue, Now) of
        ok ->
            ok;
        Updates ->
            lager:info("Overlay poller updating lashup"),
            {ok, _} = lashup_kv:request_op(Key, {update, [Updates]})
    end.

-type prefix_len() :: 0..32.
-spec(parse_subnet(Subnet :: binary()) -> {inet:ipv4_address(), prefix_len()}).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_ipv4_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 32,
    {IP, PrefixLen}.

check_subnet(
    #mesos_state_agentoverlayinfo{backend = Backend, subnet = LocalSubnet},
    _State = #state{ip = AgentIP}, LashupValue, Now) ->

    #mesos_state_backendinfo{vxlan = VXLan} = Backend,
    #mesos_state_vxlaninfo{
        vtep_ip = VTEPIPStr,
        vtep_mac = VTEPMac
    } = VXLan,
    ParsedLocalSubnet = parse_subnet(LocalSubnet),
    ParsedVTEPMac = parse_vtep_mac(VTEPMac),

    ParsedVTEPIP = parse_subnet(VTEPIPStr),
    case lists:keyfind({ParsedVTEPIP, riak_dt_map}, 1, LashupValue) of
        {{ParsedVTEPIP, riak_dt_map}, _Value} ->
            ok;
        false ->
            {update,
                {ParsedVTEPIP, riak_dt_map},
                {update, [
                    {update, {mac, riak_dt_lwwreg}, {assign, ParsedVTEPMac, Now}},
                    {update, {agent_ip, riak_dt_lwwreg}, {assign, AgentIP, Now}},
                    {update, {subnet, riak_dt_lwwreg}, {assign, ParsedLocalSubnet, Now}}
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

vtep_mac(IntList) ->
    HexList = lists:map(fun(X) -> erlang:integer_to_list(X, 16) end, IntList),
    lists:flatten(string:join(HexList, ":")).

try_configure_overlays(State0 = #state{known_overlays = KnownOverlays}) ->
   lists:foldl(
       fun try_configure_overlay/2,
       State0,
       KnownOverlays
   ).

try_configure_overlay(Overlay, State0) ->
    #mesos_state_agentoverlayinfo{info = #mesos_state_overlayinfo{subnet = Subnet}} = Overlay,
    ParsedSubnet = parse_subnet(Subnet),
    Key = [navstar, overlay, ParsedSubnet],
    LashupValue = lashup_kv:value(Key),
    lists:foldl(
        fun(Entry, Acc) -> maybe_configure_overlay_entry(Overlay, Entry, Acc) end,
        State0,
        LashupValue
    ).

maybe_configure_overlay_entry(Overlay, {{VTEPIPPrefix, riak_dt_map}, Value}, State = #state{ip = MyIP}) ->
    {_, AgentIP} = lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, Value),
    case AgentIP of
        MyIP ->
            State;
        _ ->
            configure_overlay_entry(Overlay, VTEPIPPrefix, Value, State)
    end.


configure_overlay_entry(Overlay, _VTEPIPPrefix = {VTEPIP, _PrefixLen}, LashupValue,
        State0 = #state{}) ->
    #mesos_state_agentoverlayinfo{
        backend = #mesos_state_backendinfo{
            vxlan = #mesos_state_vxlaninfo{
                vtep_name = VTEPName
            }
        }
    } = Overlay,
    {_, MAC} = lists:keyfind({mac, riak_dt_lwwreg}, 1, LashupValue),
    {_, AgentIP} = lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, LashupValue),
    {_, {SubnetIP, SubnetPrefixLen}} = lists:keyfind({subnet, riak_dt_lwwreg}, 1, LashupValue),
    FormattedMAC = vtep_mac(MAC),
    FormattedAgentIP = inet:ntoa(AgentIP),
    FormattedVTEPIP = inet:ntoa(VTEPIP),
    FormattedSubnetIP = inet:ntoa(SubnetIP),

    %ip neigh replace 5.5.5.5 lladdr ff:ff:ff:ff:ff:ff dev eth0 nud permanent
    {ok, _} = run_command("ip neigh replace ~s lladdr ~s dev ~s nud permanent",
        [FormattedVTEPIP, FormattedMAC, VTEPName]),
    %bridge fdb add to 00:17:42:8a:b4:05 dst 192.19.0.2 dev vxlan0
    {ok, _} = run_command("bridge fdb replace to ~s dst ~s dev ~s", [FormattedMAC, FormattedAgentIP, VTEPName]),

    {ok, _} = run_command("ip route replace ~s/32 via ~s table 42", [FormattedAgentIP, FormattedVTEPIP]),
    {ok, _} = run_command("ip route replace ~s/~B via ~s", [FormattedSubnetIP, SubnetPrefixLen, FormattedVTEPIP]),

    State0.

run_command(Command, Opts) ->
    Cmd = lists:flatten(io_lib:format(Command, Opts)),
    run_command(Cmd).

-spec(run_command(Command :: string()) ->
    {ok, Output :: string()} | {error, ErrorCode :: non_neg_integer(), ErrorString :: string()}).
-ifdef(DEV).
run_command("ip link show dev vtep1024") ->
    {error, 1, ""};
run_command(Command) ->
    io:format("Would run command: ~p~n", [Command]),
    {ok, ""}.
-else.
run_command(Command) ->
    Port = open_port({spawn, Command}, [stream, in, eof, hide, exit_status, stderr_to_stdout]),
    get_data(Port, []).

get_data(Port, Sofar) ->
    receive
        {Port, {data, []}} ->
            get_data(Port, Sofar);
        {Port, {data, Bytes}} ->
            get_data(Port, [Sofar|Bytes]);
        {Port, eof} ->
            return_data(Port, Sofar)
    end.
return_data(Port, Sofar) ->
    Port ! {self(), close},
    receive
        {Port, closed} ->
            true
    end,
    receive
        {'EXIT',  Port,  _} ->
            ok
    after 1 ->              % force context switch
        ok
    end,
    ExitCode =
        receive
            {Port, {exit_status, Code}} ->
                Code
        end,
    case ExitCode of
        0 ->
            {ok, lists:flatten(Sofar)};
        _ ->
            {error, ExitCode, lists:flatten(Sofar)}
    end.

-endif.

-ifdef(TEST).

deserialize_overlay_test() ->
    DataDir = code:priv_dir(dcos_overlay),
    OverlayFilename = filename:join(DataDir, "overlay.bindata.pb"),
    {ok, OverlayData} = file:read_file(OverlayFilename),
    Msg = mesos_state_overlay_pb:decode_msg(OverlayData, mesos_state_agentinfo),
    ?assertEqual(<<"10.0.0.160:5051">>, Msg#mesos_state_agentinfo.ip).

run_command_test() ->
    ?assertEqual({error, 1, ""}, run_command("false")),
    ?assertEqual({ok, ""}, run_command("true")).
-endif.