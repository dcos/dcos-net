%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%% Polls the local mesos agent if {dcos_l4lb, agent_polling_enabled} is true
%%%
%%% @end
%%% Created : 16. May 2016 5:06 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_mesos_poller).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

%% If we cannot poll the agent for this many seconds, we assume that all the tasks are lost.
-define(AGENT_TIMEOUT_SECS, 60).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([handle_poll_state/2]).
-endif.

-include("dcos_l4lb.hrl").
-include_lib("mesos_state/include/mesos_state.hrl").
-define(SERVER, ?MODULE).
-define(VIP_PORT, "VIP_PORT").

-record(state, {
    agent_ip = erlang:error() :: inet:ip4_address(),
    last_poll_time = undefined :: integer() | undefined
}).
-type state() :: #state{}.

-record(vip_be2, {
    protocol = erlang:error() :: protocol(),
    vip_ip = erlang:error() :: inet:ip_address() | {name, {binary(), binary()}},
    vip_port = erlang:error() :: inet:port_number(),
    agent_ip = erlang:error() :: inet:ip4_address(),
    backend_ip = erlang:error() :: inet:ip_address(),
    backend_port = erlang:error() :: inet:port_number()
}).

-type vip_be2() :: #vip_be2{}.

-type protocol_vip() :: {protocol(), Host :: inet:ip_address() | string(), inet:port_number()}.
-type protocol_vip_orswot() :: {protocol_vip(), riak_dt_orswot}.
-type vip_string() :: <<_:48, _:_*1>>.

%%%===================================================================
%%% API
%%%===================================================================

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

init([]) ->
    PollInterval = dcos_l4lb_config:agent_poll_interval(),
    erlang:send_after(PollInterval, self(), poll),
    AgentIP = mesos_state:ip(),
    {ok, #state{agent_ip = AgentIP}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(poll, State) ->
    NewState = maybe_poll(State),
    PollInterval = dcos_l4lb_config:agent_poll_interval(),
    _Ref = erlang:send_after(PollInterval, self(), poll),
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

maybe_poll(State) ->
    case dcos_l4lb_config:agent_polling_enabled() of
        true ->
            poll(State);
        _ ->
            State
    end.

poll(State = #state{agent_ip = AgentIP}) ->
    Port = dcos_l4lb_config:agent_port(),
    case mesos_state_client:poll(AgentIP, Port) of
        {error, Reason} ->
            %% This might generate a lot of messages?
            lager:warning("Unable to poll agent: ~p", [Reason]),
            handle_poll_failure(State);
        {ok, MesosState} ->
            handle_poll_state(MesosState, State)
    end.

%% We've never polled the agent. Or dcos_l4lb_mesos_poller has restarted.
handle_poll_failure(State = #state{last_poll_time = undefined}) ->
    State#state{last_poll_time = erlang:monotonic_time()};
handle_poll_failure(State = #state{last_poll_time = LastPollTime}) ->
    Now = erlang:monotonic_time(),
    TimeSinceLastPoll = erlang:convert_time_unit(Now - LastPollTime, native, seconds),
    handle_poll_failure(TimeSinceLastPoll, State).

handle_poll_failure(TimeSinceLastPoll, State) when TimeSinceLastPoll > ?AGENT_TIMEOUT_SECS ->
    handle_poll_changes([], State#state.agent_ip),
    State;
handle_poll_failure(_TimeSinceLastPoll, State) ->
    State.

-spec(handle_poll_state(mesos_state_client:mesos_agent_state(), state()) -> state()).
handle_poll_state(MesosState, State) ->
    VIPBEs = collect_vips(MesosState, State),
    handle_poll_changes(VIPBEs, State#state.agent_ip),
    State#state{last_poll_time = erlang:monotonic_time()}.

-spec(handle_poll_changes([vip_be2()], inet:ip4_address()) -> ok | {ok, _}).
handle_poll_changes(VIPBEs, AgentIP) ->
    LashupVIPs = lashup_kv:value(?VIPS_KEY2),
    Ops = generate_ops(AgentIP, VIPBEs, LashupVIPs),
    maybe_perform_ops(?VIPS_KEY2, Ops).

maybe_perform_ops(_, []) ->
    ok;
maybe_perform_ops(Key, Ops) ->
    lager:debug("Performing Key: ~p, Ops: ~p", [Key, Ops]),
    {ok, _} = lashup_kv:request_op(Key, {update, Ops}).

%% Generate ops generates ops in a specific order:
%% 1. Add local backends
%% 2. Remove old local backends
%% 3. Remove VIP ORSwots entirely
%% For this reason we have to reverse the ops before applying them
%% Since the way that it generates this results in this list being reversed

generate_ops(AgentIP, AgentVIPs, LashupVIPs) ->
    lists:reverse(generate_ops1(AgentIP, AgentVIPs, LashupVIPs)).

generate_ops1(AgentIP, AgentVIPs, LashupVIPs) ->
    FlatAgentVIPs = flatten_vips(AgentVIPs),
    FlatLashupVIPs = flatten_vips(LashupVIPs),
    FlatVIPsToAdd = ordsets:subtract(FlatAgentVIPs, FlatLashupVIPs),
    FlatLashupVIPsFromThisAgent = filter_vips_from_agent(AgentIP, FlatLashupVIPs),
    FlatVIPsToDel = ordsets:subtract(FlatLashupVIPsFromThisAgent, FlatAgentVIPs),
    Ops0 = lists:foldl(fun flat_vip_add_fold/2, [], FlatVIPsToAdd),
    Ops1 = lists:foldl(fun flat_vip_del_fold/2, Ops0, FlatVIPsToDel),
    add_cleanup_ops(FlatLashupVIPs, FlatVIPsToDel, Ops1).

filter_vips_from_agent(AgentIP, FlatLashupVIPs) ->
    lists:filter(fun(#vip_be2{agent_ip = AIP}) -> AIP == AgentIP end, FlatLashupVIPs).

add_cleanup_ops(FlatLashupVIPs, FlatVIPsToDel, Ops0) ->
    ExistingProtocolVIPs = lists:map(fun to_protocol_vip/1, FlatLashupVIPs),
    FlatRemainingVIPs = ordsets:subtract(FlatLashupVIPs, FlatVIPsToDel),
    RemainingProtocolVIPs =  lists:map(fun to_protocol_vip/1, FlatRemainingVIPs),
    GCVIPs = ordsets:subtract(ordsets:from_list(ExistingProtocolVIPs), ordsets:from_list(RemainingProtocolVIPs)),
    lists:foldl(fun flat_vip_gc_fold/2, Ops0, GCVIPs).

flat_vip_gc_fold(VIP, Acc) ->
    Field = {VIP, riak_dt_orswot},
    Op = {remove, Field},
    [Op | Acc].

flat_vip_add_fold(VIPBE = #vip_be2{agent_ip = AgentIP, backend_ip = BEIP, backend_port = BEPort}, Acc) ->
    Field = {to_protocol_vip(VIPBE), riak_dt_orswot},
    Op = {update, Field, {add, {AgentIP, {BEIP, BEPort}}}},
    [Op | Acc].

flat_vip_del_fold(VIPBE = #vip_be2{agent_ip = AgentIP, backend_ip = BEIP, backend_port = BEPort}, Acc) ->
    Field = {to_protocol_vip(VIPBE), riak_dt_orswot},
    Op = {update, Field, {remove, {AgentIP, {BEIP, BEPort}}}},
    [Op | Acc].

-spec(to_protocol_vip(vip_be2()) -> protocol_vip()).
to_protocol_vip(#vip_be2{vip_ip = VIPIP, protocol = Protocol, vip_port = VIPPort}) ->
    {Protocol, VIPIP, VIPPort}.

-spec(flatten_vips([{VIP :: protocol_vip() | protocol_vip_orswot(), [Backend :: ip_ip_port()]}]) -> [vip_be2()]).
flatten_vips(VIPDict) ->
    VIPBEs =
        lists:flatmap(
            fun
                ({{{Protocol, VIPIP, VIPPort}, riak_dt_orswot}, Backends}) ->
                    [#vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = BEPort,
                        backend_ip =  BEIP, agent_ip = AgentIP} || {AgentIP, {BEIP, BEPort}} <- Backends];
                ({{Protocol, VIPIP, VIPPort}, Backends}) ->
                    [#vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = BEPort,
                        backend_ip =  BEIP, agent_ip = AgentIP} || {AgentIP, {BEIP, BEPort}} <- Backends]
            end,
            VIPDict
        ),
    ordsets:from_list(VIPBEs).

-spec(maybe_disable_ipv6([vip_be2()]) -> [vip_be2()]).
maybe_disable_ipv6(VIPBEs) ->
    case application:get_env(dcos_l4lb, enable_ipv6, true) of
        false ->
            {_, VIPBEs0} = lists:partition(fun is_ipv6/1, VIPBEs),
            VIPBEs0;
        true -> VIPBEs
    end.

-spec(is_ipv6(vip_be2()) -> boolean()).
is_ipv6(#vip_be2{vip_ip = {name, _Name}, backend_ip = IPAddress}) ->
    dcos_l4lb_app:family(IPAddress) =:= inet6;
is_ipv6(#vip_be2{vip_ip = VIPIP, backend_ip = IPAddress}) ->
    VIPFamily = dcos_l4lb_app:family(VIPIP),
    BackendFamily = dcos_l4lb_app:family(IPAddress),
    VIPFamily =:= inet6 orelse BackendFamily =:= inet6.


-spec(unflatten_vips([vip_be2()]) -> [{VIP :: protocol_vip(), [Backend :: ip_ip_port()]}]).
unflatten_vips(VIPBes) ->
    VIPBEsDict =
        lists:foldl(
            fun(#vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = BEPort,
                    backend_ip = BEIP, agent_ip = AgentIP},
                Acc) ->
                orddict:append({Protocol, VIPIP, VIPPort}, {AgentIP, {BEIP, BEPort}}, Acc)
            end,
            orddict:new(),
            VIPBes
        ),
    orddict:map(fun(_Key, Value) -> ordsets:from_list(Value) end, VIPBEsDict).

-spec is_healthy(task() | task_status()) -> boolean().
is_healthy(#task{state = running, statuses = []}) ->
    true;
is_healthy(#task{state = running, statuses = TaskStatuses}) ->
    TaskStatuses0 = lists:keysort(#task_status.timestamp, TaskStatuses),
    TaskStatus = lists:last(TaskStatuses0),
    is_healthy(TaskStatus);
is_healthy(#task_status{state = running, healthy = undefined}) ->
    true;
is_healthy(#task_status{state = running, healthy = true}) ->
    true;
is_healthy(_) ->
    false.

-spec(collect_vips(MesosState :: mesos_state_client:mesos_agent_state(), State :: state()) ->
    [{VIP :: protocol_vip(), [Backend :: ip_ip_port()]}]).
collect_vips(MesosState, _State) ->
    Tasks = mesos_state_client:tasks(MesosState),
    Tasks1 = lists:filter(fun is_healthy/1, Tasks),
    VIPBEs = collect_vips_from_tasks_labels(Tasks1, ordsets:new()),
    VIPBEs1 = collect_vips_from_discovery_info(Tasks1, VIPBEs),
    VIPBEs2 = maybe_disable_ipv6(VIPBEs1),
    VIPBes3 = lists:usort(VIPBEs2),
    unflatten_vips(VIPBes3).

collect_vips_from_discovery_info([], VIPBEs) ->
    VIPBEs;
collect_vips_from_discovery_info([Task | Tasks], VIPBEs) ->
    VIPBEs1 =
        case catch collect_vips_from_discovery_info(Task) of
            {'EXIT', Reason} ->
                lager:warning("Failed to parse task (discoveryinfo): ~p", [Reason]),
                VIPBEs;
            AdditionalVIPBEs ->
                ordsets:union(ordsets:from_list(AdditionalVIPBEs), VIPBEs)
        end,
    collect_vips_from_discovery_info(Tasks, VIPBEs1).


collect_vips_from_discovery_info(_Task = #task{discovery = undefined}) ->
    [];
collect_vips_from_discovery_info(Task = #task{discovery = #discovery{ports = Ports}}) ->
    collect_vips_from_discovery_info(Ports, Task, []).


-spec(collect_vips_from_discovery_info([mesos_port()], task(), [vip_be2()]) -> [vip_be2()]).
collect_vips_from_discovery_info([], _Task, Acc) ->
    Acc;
collect_vips_from_discovery_info([Port = #mesos_port{labels = PortLabels}| Ports],
        Task, Acc) ->
    VIPLabels =
        maps:filter(
            fun(Key, _Value) ->
                nomatch =/= binary:match(Key, [<<"VIP">>, <<"vip">>])
            end,
            PortLabels
        ),
    VIPBins = [{VIPBin, Task} || {_, VIPBin} <- maps:to_list(VIPLabels)],
    VIPs = lists:map(fun parse_vip/1, VIPBins),
    BEs = collect_vips_from_discovery_info_fold(PortLabels, VIPs, Port, Task),
    collect_vips_from_discovery_info(Ports, Task, BEs ++ Acc).


-type name_or_ip() :: inet:ip_address() | {name, Hostname :: binary(), FrameworkName :: framework_name()}.
-type vips() :: {name_or_ip(), inet:port_number()}.
-spec(collect_vips_from_discovery_info_fold(LabelBin :: map(), [vips()], mesos_port(), task()) -> [vip_be2()]).
collect_vips_from_discovery_info_fold(_PortLabels, [], _Port, _Task) ->
    [];
collect_vips_from_discovery_info_fold(_PortLabels, _VIPs,
    #mesos_port{protocol = Protocol}, #task{name = TaskName}) when Protocol =/= tcp, Protocol =/= udp ->
    lager:warning("Unsupported protocol ~p in task ~p", [Protocol, TaskName]),
    [];
collect_vips_from_discovery_info_fold(#{<<"network-scope">> := <<"container">>}, VIPs,
    #mesos_port{protocol = Protocol, number = PortNum}, Task) ->
    Slave = Task#task.slave,
    #libprocess_pid{ip = AgentIP} = Slave#slave.pid,
    #task{statuses = [#task_status{container_status = #container_status{
          network_infos = [#network_info{ip_addresses = IPAddresses}|_]}}|_]} = Task,
    [#vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol,
              backend_port = PortNum, backend_ip =  IPAddress,
              agent_ip = AgentIP} || {VIPIP, VIPPort} <- VIPs,
              #ip_address{ip_address = IPAddress} <- IPAddresses];
collect_vips_from_discovery_info_fold(_PortLabels, VIPs,
    #mesos_port{protocol = Protocol, number = PortNum}, Task) ->
    Slave = Task#task.slave,
    #libprocess_pid{ip = AgentIP} = Slave#slave.pid,
    [#vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = PortNum,
        backend_ip =  AgentIP, agent_ip = AgentIP} || {VIPIP, VIPPort} <- VIPs].

%({binary(),_}) -> {{'name',{binary(),'undefined' | binary()}} | {byte(),byte(),byte(),byte()},'error' | integer()}

-type label_value() :: binary().
-spec(parse_vip({LabelBin :: label_value(), task()}) -> {name_or_ip(), inet:port_number()}).
parse_vip({LabelBin, Task = #task{}}) ->
    [HostBin, PortBin] = string:split(LabelBin, <<":">>, trailing),
    HostStr = binary_to_list(HostBin),
    Host =
        case inet:parse_address(HostStr) of
            {ok, HostIP} ->
                HostIP;
            _ ->
                #task{framework = #framework{name = FrameworkName}} = Task,
                {name, {HostBin, FrameworkName}}
        end,
    PortStr = binary_to_list(PortBin),
    {Port, []} = string:to_integer(PortStr),
    true = is_integer(Port),
    {Host, Port}.


collect_vips_from_tasks_labels([], VIPBEs) ->
    VIPBEs;
collect_vips_from_tasks_labels([Task | Tasks], VIPBEs) ->
    VIPBEs1 =
        case catch collect_vips_from_task_labels(Task) of
            {'EXIT', Reason} ->
                lager:warning("Failed to parse task (labels): ~p", [Reason]),
                VIPBEs;
            AdditionalVIPBEs ->
                ordsets:union(ordsets:from_list(AdditionalVIPBEs), VIPBEs)
        end,
    collect_vips_from_tasks_labels(Tasks, VIPBEs1).

collect_vips_from_task_labels(Task = #task{labels = TaskLabels}) ->
    VIPLabelsKeys0 = maps:keys(TaskLabels),

    VIPLabelsKeys1 =
        lists:filter(
            fun(Key) ->
                KeyStr = binary_to_list(Key),
                KeyStrUpper = string:to_upper(KeyStr),
                string:str(KeyStrUpper, ?VIP_PORT) == 1
            end,
            VIPLabelsKeys0
        ),
    collect_vips_from_task_labels_fold(VIPLabelsKeys1, Task, []).


collect_vips_from_task_labels_fold([], _Task, Acc) ->
    Acc;

collect_vips_from_task_labels_fold([VIPLabelKeyBin | VIPLabelKeys],
        Task = #task{labels =  TaskLabels, resources = Resources}, Acc) ->
    Slave = Task#task.slave,
    #libprocess_pid{ip = AgentIP} = Slave#slave.pid,

    VIPLabelStr = binary_to_list(VIPLabelKeyBin),
    TaskPortIdxStr = string:sub_string(VIPLabelStr, string:len(?VIP_PORT) + 1),
    {TaskPortIdx, []} = string:to_integer(TaskPortIdxStr),
    LabelValue = maps:get(VIPLabelKeyBin, TaskLabels),
    {Protocol, VIPIP, VIPPort} = normalize_vip(LabelValue),
    Ports = maps:get(ports, Resources),
    BEPort = lists:nth(TaskPortIdx + 1, Ports),
    VIPBE = #vip_be2{
        protocol = Protocol,
        vip_ip = VIPIP,
        vip_port = VIPPort,
        agent_ip = AgentIP,
        backend_ip = AgentIP,
        backend_port = BEPort
    },
    collect_vips_from_task_labels_fold(VIPLabelKeys, Task, [VIPBE | Acc]).


-spec normalize_vip(vip_string()) -> {tcp | udp, inet:ip4_address(), inet:port_number()} | {error, string()}.
normalize_vip(<<"tcp://", Rest/binary>>) ->
    parse_host_port(tcp, Rest);
normalize_vip(<<"udp://", Rest/binary>>) ->
    parse_host_port(udp, Rest);
normalize_vip(E) ->
    {error, {bad_vip_specification, E}}.

parse_host_port(Proto, Rest) ->
    RestStr = binary_to_list(Rest),
    case string:tokens(RestStr, ":") of
        [HostStr, PortStr] ->
            parse_host_port(Proto, HostStr, PortStr);
        _ ->
            {error, {bad_vip_specification, Rest}}
    end.

parse_host_port(Proto, HostStr, PortStr) ->
    case inet:parse_address(HostStr) of
        {ok, Host} ->
            parse_host_port_2(Proto, Host, PortStr);
        {error, einval} ->
            {error, {bad_host_string, HostStr}}
    end.

parse_host_port_2(Proto, Host, PortStr) ->
    case string_to_integer(PortStr) of
        error ->
            {error, {bad_port_string, PortStr}};
        Port ->
            {Proto, Host, Port}
    end.

-spec string_to_integer(string()) -> pos_integer() | error.
string_to_integer(Str) ->
    {Int, _Rest} = string:to_integer(Str),
    Int.

-ifdef(TEST).
fake_state() ->
    #state{agent_ip = {0, 0, 0, 0}}.

overlay_vips_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/overlay.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
           {tcp, {1, 2, 3, 4}, 5000},
           [
              {{10, 0, 1, 248}, {{9, 0, 1, 130}, 80}}
           ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

two_healthcheck_free_vips_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/two-healthcheck-free-vips-state.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {4, 3, 2, 1}, 1234},
                [
                    {{33, 33, 33, 1}, {{33, 33, 33, 1}, 31362}},
                    {{33, 33, 33, 1}, {{33, 33, 33, 1}, 31634}}
                ]
        },
        {
            {tcp, {4, 3, 2, 2}, 1234},
                [
                    {{33, 33, 33, 1}, {{33, 33, 33, 1}, 31215}},
                    {{33, 33, 33, 1}, {{33, 33, 33, 1}, 31290}}
                ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state2_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state2.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 5000},
            [
                {{10, 10, 0, 109}, {{10, 10, 0, 109}, 8014}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state3_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state3.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 5000},
            [
                {{10, 0, 0, 243}, {{10, 0, 0, 243}, 26645}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state4_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state4.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 5000},
            [
                {{10, 0, 0, 243}, {{10, 0, 0, 243}, 26645}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state5_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state5.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 5000},
            [
                {{10, 0, 0, 243}, {{10, 0, 0, 243}, 26645}}
            ]
        },
        {
            {udp, {1, 2, 3, 4}, 5000},
            [
                {{10, 0, 0, 243}, {{10, 0, 0, 243}, 26645}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

state6_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state6.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 80},
            [
                {{172, 18, 0, 3}, {{9, 0, 1, 130}, 80}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

ipv6_vip_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state_ipv6.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {name, {<<"/foo">>, <<"marathon">>}}, 80},
            [
              {{10, 0, 2, 74}, {{12, 0, 1, 4}, 80}},
              {{10, 0, 2, 74}, {{16#fd01, 16#0, 16#0, 16#0, 16#0, 16#1, 16#8000, 16#4}, 80}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

ipv6_vip2_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state2_ipv6.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {16#fd01, 16#d, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, 80},
            [
              {{10, 0, 0, 230}, {{172, 18, 0, 2}, 80}},
              {{10, 0, 0, 230}, {{16#fd01, 16#b, 16#0, 16#0, 16#2, 16#8000, 16#0, 16#2}, 80}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).

disable_ipv6_vip_test_() ->
    {setup, fun () ->
        ok = application:load(dcos_l4lb),
        application:set_env(dcos_l4lb, enable_ipv6, false)
    end, fun (_) ->
        ok = application:unset_env(dcos_l4lb, enable_ipv6),
        ok = application:unload(dcos_l4lb)
    end, [
        fun () ->
            {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state_ipv6.json"),
            {ok, MesosState} = mesos_state_client:parse_response(Data),
            VIPBes = collect_vips(MesosState, fake_state()),
            Expected = [
                {
                    {tcp, {name, {<<"/foo">>, <<"marathon">>}}, 80},
                    [
                      {{10, 0, 2, 74}, {{12, 0, 1, 4}, 80}}
                    ]
                }
            ],
            ?assertEqual(Expected, VIPBes)
        end,
        fun () ->
            {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state2_ipv6.json"),
            {ok, MesosState} = mesos_state_client:parse_response(Data),
            VIPBes = collect_vips(MesosState, fake_state()),
            ?assertEqual([], VIPBes)
        end
    ]}.

di_state_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/state_di.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {1, 2, 3, 4}, 8080},
            [
                {{10, 0, 2, 234}, {{10, 0, 2, 234}, 19426}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).


named_vips_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/named-base-vips.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [
        {
            {tcp, {name, {<<"merp">>, <<"marathon">>}}, 5000},
            [
                {{10, 0, 0, 243}, {{10, 0, 0, 243}, 12049}}
            ]
        }
    ],
    ?assertEqual(Expected, VIPBes).


missing_port_test() ->
    {ok, Data} = file:read_file("apps/dcos_l4lb/testdata/missing-port.json"),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    VIPBes = collect_vips(MesosState, fake_state()),
    Expected = [],
    ?assertEqual(Expected, VIPBes).

filter_vips_test() ->
    AgentIP = {1, 1, 1, 1},
    FakeAgentIP = {1, 1, 1, 2},
    VIP1 = {2, 2, 2, 2},
    VIP2 = {2, 2, 2, 3},
    FlatVIPs = [#vip_be2{vip_ip = VIP1, agent_ip = AgentIP, protocol = tcp,
                         vip_port = 5000, backend_ip = {10, 0, 0, 243}, backend_port = 12049},
                #vip_be2{vip_ip = VIP2, agent_ip = FakeAgentIP, protocol = tcp,
                         vip_port = 5000, backend_ip = {10, 0, 0, 243}, backend_port = 12049}],
   FilterVIPs = filter_vips_from_agent(AgentIP, FlatVIPs),
   Expected = [#vip_be2{vip_ip = VIP1, agent_ip = AgentIP, protocol = tcp, vip_port = 5000,
               backend_ip = {10, 0, 0, 243}, backend_port = 12049}],
   ?assertEqual(Expected, FilterVIPs).

flatten_vips_test() ->
   VIPDict = [
        {
            {tcp, {2, 2, 2, 2}, 5000},
            [
                {{1, 1, 1, 1}, {{10, 0, 0, 243}, 12049}}
            ]
        }
    ],
    FlatVIPs = flatten_vips(VIPDict),
    Expected = [#vip_be2{vip_ip = {2, 2, 2, 2}, vip_port = 5000, protocol = tcp,
                         agent_ip = {1, 1, 1, 1}, backend_port = 12049, backend_ip = {10, 0, 0, 243}}],
    ?assertEqual(Expected, FlatVIPs).
-endif.
