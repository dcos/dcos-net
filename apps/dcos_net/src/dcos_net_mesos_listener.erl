-module(dcos_net_mesos_listener).

%% API
-export([
    start_link/0,
    subscribe/0,
    is_leader/0,
    next/1,
    poll/0,
    from_state/1,
    init_metrics/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-export_type([task_id/0, task/0, task_state/0, task_port/0, runtime/0]).

-opaque task_id() :: {framework_id(), binary()}.
-type framework_id() :: binary().
-type task() :: #{
    name => binary(),
    framework => binary() | {id, binary()},
    runtime => runtime(),
    agent_ip => inet:ip4_address() | {id, binary()},
    task_ip => [inet:ip_address()],
    state => task_state(),
    healthy => boolean(),
    ports => [task_port()]
}.
-type runtime() :: docker | mesos | unknown.
-type task_state() :: preparing | running | terminal.
-type task_port() :: #{
    name => binary(),
    host_port => inet:port_number(),
    port => inet:port_number(),
    protocol => tcp | udp,
    vip => [binary()]
}.

-record(state, {
    pid :: pid(),
    ref :: reference(),
    size = undefined :: pos_integer() | undefined,
    buf = <<>> :: binary(),
    timeout = 15000 :: timeout(),
    timeout_ref = make_ref() :: reference(),
    agents = #{} :: #{binary() => inet:ip4_address()},
    frameworks = #{} :: #{framework_id() => binary()},
    tasks = #{} :: #{task_id() => task()},
    waiting_tasks = #{} :: #{task_id() => true},
    subs = undefined :: #{pid() => reference()} | undefined
}).

-type state() :: #state{}.

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec(subscribe() -> {ok, MonRef, Tasks} | {error, atom()}
    when MonRef :: reference(), Tasks :: #{task_id() => task()}).
subscribe() ->
    case whereis(?MODULE) of
        undefined ->
            {error, not_found};
        Pid ->
            subscribe(Pid)
    end.

-spec(next(reference()) -> ok).
next(Ref) ->
    ?MODULE ! {next, Ref},
    ok.

-spec(is_leader() -> boolean()).
is_leader() ->
    try
        gen_server:call(?MODULE, is_leader)
    catch _Class:_Error ->
        false
    end.

-spec(poll() -> {ok, #{task_id() => task()}} | {error, term()}).
poll() ->
    case poll_imp() of
        {ok, Obj} ->
            {ok, from_state(Obj)};
        {error, Error} ->
            {error, Error}
    end.

-spec(from_state(jiffy:object()) -> #{task_id() => task()}).
from_state(Data) ->
    from_state_imp(Data).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! init,
    {ok, []}.

handle_call(is_leader, _From, State) ->
    % There is no state if it's not connected
    IsLeader = is_record(State, state),
    {reply, IsLeader, State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, []) ->
    {noreply, handle_init([])};
handle_info({subscribe, Pid, Ref}, State) ->
    {noreply, handle_subscribe(Pid, Ref, State)};
handle_info({http, {Ref, stream, Data}}, #state{ref=Ref}=State) ->
    handle_stream(Data, State);
handle_info({timeout, TRef, httpc}, #state{ref=Ref, timeout_ref=TRef}=State) ->
    ok = httpc:cancel_request(Ref),
    lager:error("Mesos timeout"),
    {stop, {httpc, timeout}, State};
handle_info({http, {Ref, {error, Error}}}, #state{ref=Ref}=State) ->
    lager:error("Mesos connection terminated: ~p", [Error]),
    {stop, Error, State};
handle_info({'DOWN', _MonRef, process, Pid, Info}, #state{pid=Pid}=State) ->
    lager:error("Mesos http client: ~p", [Info]),
    {stop, Info, State};
handle_info({'DOWN', _MonRef, process, Pid, _Info}, State) ->
    {noreply, handle_unsubscribe(Pid, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(normal, _State) ->
    ok;
terminate(_Reason, _State) ->
    prometheus_counter:inc(mesos_listener, failures_total, [], 1).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Handle functions
%%%===================================================================

-spec(handle(jiffy:object(), state()) -> state()).
handle(#{<<"type">> := <<"SUBSCRIBED">>} = Obj, State) ->
    Obj0 = mget(<<"subscribed">>, Obj),
    handle_subscribed(Obj0, State);
handle(#{<<"type">> := <<"HEARTBEAT">>}, State) ->
    handle_heartbeat(State);
handle(#{<<"type">> := <<"TASK_ADDED">>} = Obj, State) ->
    Obj0 = mget(<<"task_added">>, Obj),
    handle_task_added(Obj0, State);
handle(#{<<"type">> := <<"TASK_UPDATED">>} = Obj, State) ->
    Obj0 = mget(<<"task_updated">>, Obj),
    handle_task_updated(Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_ADDED">>} = Obj, State) ->
    Obj0 = mget(<<"framework_added">>, Obj),
    handle_framework_added(Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_UPDATED">>} = Obj, State) ->
    Obj0 = mget(<<"framework_updated">>, Obj),
    handle_framework_updated(Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_REMOVED">>} = Obj, State) ->
    Obj0 = mget(<<"framework_removed">>, Obj),
    handle_framework_removed(Obj0, State);
handle(#{<<"type">> := <<"AGENT_ADDED">>} = Obj, State) ->
    Obj0 = mget(<<"agent_added">>, Obj),
    handle_agent_added(Obj0, State);
handle(#{<<"type">> := <<"AGENT_REMOVED">>} = Obj, State) ->
    Obj0 = mget(<<"agent_removed">>, Obj),
    handle_agent_removed(Obj0, State);
handle(Obj, State) ->
    lager:error("Unexpected mesos message type: ~p", [Obj]),
    State.

-spec(handle_subscribed(jiffy:object(), state()) -> state()).
handle_subscribed(Obj, State) ->
    Timeout = mget(<<"heartbeat_interval_seconds">>, Obj),
    Timeout0 = erlang:trunc(Timeout * 1000),
    State0 = State#state{timeout = Timeout0},

    MState = mget(<<"get_state">>, Obj, #{}),

    Agents = mget([<<"get_agents">>, <<"agents">>], MState, []),
    State1 =
        lists:foldl(fun (Agent, St) ->
            handle_agent_added(#{<<"agent">> => Agent}, St)
        end, State0, Agents),

    Frameworks = mget([<<"get_frameworks">>, <<"frameworks">>], MState, []),
    State2 =
        lists:foldl(fun (Framework, St) ->
            handle_framework_updated(#{<<"framework">> => Framework}, St)
        end, State1, Frameworks),

    Tasks = mget([<<"get_tasks">>, <<"tasks">>], MState, []),
    State3 =
        lists:foldl(fun (Task, St) ->
            handle_task(Task, St)
        end, State2, Tasks),

    State4 = State3#state{subs=#{}},

    erlang:garbage_collect(),
    handle_heartbeat(State4).

-spec(handle_heartbeat(state()) -> state()).
handle_heartbeat(#state{timeout = T, timeout_ref = TRef}=State) ->
    TRef0 = erlang:start_timer(3 * T, self(), httpc),
    _ = erlang:cancel_timer(TRef),
    State#state{timeout_ref=TRef0}.

-spec(handle_task_added(jiffy:object(), state()) -> state()).
handle_task_added(Obj, State) ->
    Task = mget(<<"task">>, Obj),
    handle_task(Task, State).

-spec(handle_task_updated(jiffy:object(), state()) -> state()).
handle_task_updated(Obj, State) ->
    Task = mget(<<"status">>, Obj),
    FrameworkId = mget(<<"framework_id">>, Obj),
    Task0 = mput(<<"framework_id">>, FrameworkId, Task),

    % NOTE: Always depend on TaskState, it is more accurate
    % JIRA: https://jira.mesosphere.com/browse/DCOS_OSS-3539
    TaskState = mget(<<"state">>, Obj),
    Task1 = mput(<<"state">>, TaskState, Task0),

    handle_task(Task1, State).

-spec(handle_framework_added(jiffy:object(), state()) -> state()).
handle_framework_added(Obj, State) ->
    handle_framework_updated(Obj, State).

-spec(handle_framework_updated(jiffy:object(), state()) -> state()).
handle_framework_updated(Obj, #state{frameworks=F}=State) ->
    FObj = mget(<<"framework">>, Obj),
    #{id := Id, name := Name} = handle_framework(FObj),

    lager:notice("Framework ~s added, ~s", [Id, Name]),
    State0 = State#state{frameworks=mput(Id, Name, F)},
    handle_waiting_tasks(framework, Id, Name, State0).

-spec(handle_framework_removed(jiffy:object(), state()) -> state()).
handle_framework_removed(Obj, #state{frameworks=F}=State) ->
    #{id := Id} = handle_framework(Obj),
    lager:notice("Framework ~s removed", [Id]),
    State#state{frameworks=mremove(Id, F)}.

-spec(handle_framework(jiffy:object()) ->
    #{id => binary(), name => binary() | undefined}).
handle_framework(Obj) ->
    Info = mget(<<"framework_info">>, Obj),
    Id = mget([<<"id">>, <<"value">>], Info),
    Name = mget(<<"name">>, Info, undefined),
    #{id => Id, name => Name}.

-spec(handle_agent_added(jiffy:object(), state()) -> state()).
handle_agent_added(Obj, #state{agents=A}=State) ->
    AObj = mget(<<"agent">>, Obj),
    #{id := Id, ip := IP} = handle_agent(AObj),
    lager:notice("Agent ~s added, ~p", [Id, IP]),
    State0 = State#state{agents=mput(Id, IP, A)},
    handle_waiting_tasks(agent_ip, Id, IP, State0).

-spec(handle_agent_removed(jiffy:object(), state()) -> state()).
handle_agent_removed(Obj, #state{agents=A}=State) ->
    Id = mget([<<"agent_id">>, <<"value">>], Obj),
    lager:notice("Agent ~s removed", [Id]),
    State#state{agents=mremove(Id, A)}.

-spec(handle_agent(jiffy:object()) ->
    #{id => binary(), ip => inet:ip4_address() | undefined}).
handle_agent(Obj) ->
    Info = mget(<<"agent_info">>, Obj),
    Id =
        try
            mget([<<"id">>, <<"value">>], Info)
        catch error:{badkey, <<"id">>} ->
            error(bad_agent_id)
        end,
    Hostname = mget(<<"hostname">>, Info, undefined),
    AgentIP = handle_agent_hostname(Hostname),
    #{id => Id, ip => AgentIP}.

-spec(handle_agent_hostname(binary() | undefined) ->
    inet:ip4_address() | undefined).
handle_agent_hostname(Hostname) ->
    % `Hostname` is an IP address or a DNS name.
    case dcos_dns:resolve(Hostname) of
        {ok, [IP]} ->
            IP;
        {ok, [IP|IPs]} ->
            lager:warning(
                "Unexpected agent ips were ignored, ~s -> ~p: ~p",
                [Hostname, IP, IPs]),
            IP;
        {error, Error} ->
            lager:error(
                "Couldn't resolve agent hostname, ~s: ~p",
                [Hostname, Error]),
            undefined
    end.

%%%===================================================================
%%% Handle task functions
%%%===================================================================

-spec(handle_task(jiffy:object(), state()) -> state()).
handle_task(TaskObj, #state{tasks=T}=State) ->
    FrameworkId = mget([<<"framework_id">>, <<"value">>], TaskObj),
    TaskId = {FrameworkId, mget([<<"task_id">>, <<"value">>], TaskObj)},
    Task = maps:get(TaskId, T, #{}),
    handle_task(TaskId, TaskObj, Task, State).

-spec(handle_task(
    task_id(), jiffy:object(),
    task(), state()) -> state()).
handle_task(TaskId, TaskObj, Task,
            State=#state{agents=A, frameworks=F}) ->
    try
        Task0 = task(TaskObj, Task, A, F),
        add_task(TaskId, Task, Task0, State)
    catch Class:Error ->
        lager:error(
            "Unexpected error with ~s [~p]: ~p",
            [id2bin(TaskId), Class, Error]),
        State
    end.

-spec(task(TaskObj, task(), Agent, Framework) -> task()
    when TaskObj :: jiffy:object(),
         Agent :: #{binary() => inet:ip4_address()},
         Framework :: #{binary() => binary()}).
task(TaskObj, Task, Agents, Frameworks) ->
    AgentId = mget([<<"agent_id">>, <<"value">>], TaskObj),
    Agent = mget(AgentId, Agents, {id, AgentId}),

    FrameworkId = mget([<<"framework_id">>, <<"value">>], TaskObj),
    Framework = mget(FrameworkId, Frameworks, {id, FrameworkId}),

    Fields = [
        {name, fun handle_task_name/2},
        {task_ip, fun handle_task_ip/2},
        {state, fun handle_task_state/2},
        {healthy, fun handle_task_healthy/2},
        {ports, fun handle_task_ports/2},
        {runtime, fun handle_task_runtime/2}
    ],
    Task0 = mput(agent_ip, Agent, Task),
    Task1 = mput(framework, Framework, Task0),
    lists:foldl(fun ({Key, Fun}, Acc) ->
        try Fun(TaskObj, Acc) of Value ->
            mput(Key, Value, Acc)
        catch Class:Error ->
            lager:error(
                "Unexpected error with ~p [~p]: ~p",
                [Key, Class, Error]),
            Acc
        end
    end, Task1, Fields).

-spec(add_task(task_id(), task(), task(), state()) -> state()).
add_task(TaskId, TaskPrev, TaskNew, State) ->
    case mdiff(TaskPrev, TaskNew) of
        MDiff when map_size(MDiff) =:= 0 ->
            State;
        MDiff ->
            lager:notice("Task ~s updated with ~p", [id2bin(TaskId), MDiff]),
            add_task(TaskId, TaskNew, State)
    end.

-spec(add_task(task_id(), task(), state()) -> state()).
add_task(TaskId, #{state := terminal} = Task, #state{
        tasks=T, waiting_tasks=TW}=State) ->
    State0 = notify(TaskId, Task, State),
    State0#state{
        tasks=mremove(TaskId, T),
        waiting_tasks=mremove(TaskId, TW)};
add_task(TaskId, Task, #state{tasks=T, waiting_tasks=TW}=State) ->
    % NOTE: you can get task info before you get agent or framework
    {TW0, State0} =
        case Task of
            #{agent_ip := {id, _Id}} ->
                {mput(TaskId, true, TW), State};
            #{framework := {id, _Id}} ->
                {mput(TaskId, true, TW), State};
            _Task ->
                St = notify(TaskId, Task, State),
                {mremove(TaskId, TW), St}
        end,
    State0#state{
        tasks=mput(TaskId, Task, T),
        waiting_tasks=TW0}.

-spec(handle_waiting_tasks(
    agent_ip | framework, binary(),
    term(), state()) -> state()).
handle_waiting_tasks(Key, Id, Value, #state{waiting_tasks=TW}=State) ->
    maps:fold(fun(TaskId, true, #state{tasks=T}=Acc) ->
        Task = maps:get(TaskId, T),
        case maps:get(Key, Task) of
            {id, Id} ->
                lager:notice(
                    "Task ~s updated with ~p",
                    [id2bin(TaskId), #{Key => Value}]),
                add_task(TaskId, mput(Key, Value, Task), Acc);
            _KValue ->
                Acc
        end
    end, State, TW).

id2bin({FrameworkId, TaskId}) ->
    <<TaskId/binary, " by ", FrameworkId/binary>>.

%%%===================================================================
%%% Handle task fields
%%%===================================================================

% NOTE: See isTerminalState (#L91-L101) in
% https://github.com/apache/mesos/blob/1.5.0/src/common/protobuf_utils.cpp
-define(IS_TERMINAL(S),
    S =:= <<"TASK_FINISHED">> orelse
    S =:= <<"TASK_FAILED">> orelse
    S =:= <<"TASK_KILLED">> orelse
    S =:= <<"TASK_LOST">> orelse
    S =:= <<"TASK_ERROR">> orelse
    S =:= <<"TASK_DROPPED">> orelse
    S =:= <<"TASK_GONE">> orelse
    S =:= <<"TASK_GONE_BY_OPERATOR">>
).

-spec(handle_task_state(jiffy:object(), task()) -> task_state()).
handle_task_state(TaskObj, _Task) ->
    case maps:get(<<"state">>, TaskObj) of
        TaskState when ?IS_TERMINAL(TaskState) ->
            terminal;
        <<"TASK_RUNNING">> ->
            running;
        _TaskState ->
            preparing
    end.

-spec(handle_task_healthy(jiffy:object(), task()) -> undefined | boolean()).
handle_task_healthy(TaskObj, _Task) ->
    IsHealthy =
        case maps:is_key(<<"health_check">>, TaskObj) of
            false -> undefined;
            true -> false
        end,
    Status = handle_task_status(TaskObj),
    mget(<<"healthy">>, Status, IsHealthy).

-spec(handle_task_name(jiffy:object(), task()) -> binary() | undefined).
handle_task_name(TaskObj, _Task) ->
    Name = mget(<<"name">>, TaskObj, undefined),
    mget([<<"discovery">>, <<"name">>], TaskObj, Name).

-spec(handle_task_runtime(jiffy:object(), task()) -> runtime()).
handle_task_runtime(TaskObj, Task) ->
    Default = maps:get(runtime, Task, unknown),
    try mget([<<"container">>, <<"type">>], TaskObj) of
        <<"MESOS">> ->
            mesos;
        <<"DOCKER">> ->
            docker;
        Type ->
            lager:warning("Received an unknown container runtime
                ~p for task ~p", [Type, Task]),
            unknown
    catch error:{badkey, _} ->
        Default
    end.

-spec(handle_task_ip(jiffy:object(), task()) -> [inet:ip_address()]).
handle_task_ip(TaskObj, _Task) ->
    Status = handle_task_status(TaskObj),
    NetworkInfos =
        mget([<<"container_status">>, <<"network_infos">>], Status, []),
    [ IPAddress ||
        NetworkInfo <- NetworkInfos,
        #{<<"ip_address">> := IP} <- mget(<<"ip_addresses">>, NetworkInfo),
        {ok, IPAddress} <- [inet:parse_strict_address(binary_to_list(IP))] ].

-spec(handle_task_ports(jiffy:object(), task()) -> [task_port()] | undefined).
handle_task_ports(TaskObj, Task) ->
    PortMappings = handle_task_port_mappings(TaskObj),
    PortResources = handle_task_port_resources(TaskObj),
    DiscoveryPorts = handle_task_discovery_ports(TaskObj, Task),
    Ports = merge_task_ports(PortMappings, PortResources, DiscoveryPorts),
    merge_host_ports(Task, Ports).

-spec(handle_task_port_mappings(jiffy:object()) -> [task_port()]).
handle_task_port_mappings(TaskObj) ->
    Type = mget([<<"container">>, <<"type">>], TaskObj, <<"MESOS">>),
    handle_task_port_mappings(Type, TaskObj).

-spec(handle_task_port_mappings(binary(), jiffy:object()) -> [task_port()]).
handle_task_port_mappings(<<"MESOS">>, TaskObj) ->
    Status = handle_task_status(TaskObj),
    PodNetworkInfos =
        mget([<<"container_status">>, <<"network_infos">>], Status, []),
    NetworkInfos =
        mget([<<"container">>, <<"network_infos">>], TaskObj, PodNetworkInfos),
    PortMappings =
        lists:flatmap(
            fun (NetworkInfo) ->
                mget(<<"port_mappings">>, NetworkInfo, [])
            end, NetworkInfos),
    handle_port_mappings(PortMappings);
handle_task_port_mappings(<<"DOCKER">>, TaskObj) ->
    DockerObj = mget([<<"container">>, <<"docker">>], TaskObj, #{}),
    PortMappings = mget(<<"port_mappings">>, DockerObj, []),
    handle_port_mappings(PortMappings).

-spec(handle_port_mappings(jiffy:object()) -> [task_port()]).
handle_port_mappings(PortMappings) when is_list(PortMappings) ->
    lists:flatmap(fun handle_port_mappings/1, PortMappings);
handle_port_mappings(PortMapping) ->
    Port = mget(<<"container_port">>, PortMapping),
    HostPort = mget(<<"host_port">>, PortMapping),
    try handle_protocol(PortMapping) of Protocol ->
        [#{protocol => Protocol, port => Port, host_port => HostPort}]
    catch throw:unexpected_protocol ->
        []
    end.

-spec(handle_protocol(jiffy:object()) -> tcp | udp).
handle_protocol(Obj) ->
    Protocol = mget(<<"protocol">>, Obj),
    case cowboy_bstr:to_lower(Protocol) of
        <<"tcp">> -> tcp;
        <<"udp">> -> udp;
        _Protocol ->
            lager:warning("Unexpected protocol type: ~p", [Obj]),
            throw(unexpected_protocol)
    end.

-spec(handle_task_port_resources(jiffy:object()) -> [task_port()]).
handle_task_port_resources(TaskObj) ->
    TaskLabels = mget([<<"labels">>, <<"labels">>], TaskObj, []),
    TaskVIPLabels = handle_task_vip_labels(TaskLabels),
    Resources = mget(<<"resources">>, TaskObj, []),
    Ports = lists:flatmap(fun expand_ports/1, Resources),
    handle_task_port_resources(Ports, TaskVIPLabels).

-spec(expand_ports(jiffy:object()) -> [inet:port_number()]).
expand_ports(#{<<"name">> := <<"ports">>,
               <<"type">> := <<"RANGES">>,
               <<"ranges">> := #{<<"range">> := Ranges}}) ->
    lists:flatmap(fun (#{<<"begin">> := Begin, <<"end">> := End}) ->
        lists:seq(Begin, End)
    end, Ranges);
expand_ports(#{<<"name">> := <<"ports">>,
               <<"type">> := <<"SCALAR">>,
               <<"scalar">> := #{<<"value">> := Port}}) ->
    [Port];
expand_ports(_Obj) ->
    [].

-spec(handle_task_port_resources(Ports, TaskVIPLabels) -> [task_port()]
    when Ports :: [inet:port_number()],
         TaskVIPLabels :: [{non_neg_integer(), tcp | udp, binary()}]).
handle_task_port_resources(Ports, TaskVIPLabels) ->
    lists:map(fun ({Idx, Protocol, Label}) ->
        Port = lists:nth(Idx + 1, Ports),
        #{host_port => Port, protocol => Protocol, vip => [Label]}
    end, TaskVIPLabels).

-spec(handle_task_vip_labels([jiffy:object()]) ->
    [{non_neg_integer(), tcp | udp, binary()}]).
handle_task_vip_labels(Labels) ->
    lists:flatmap(fun handle_task_vip_label/1, Labels).

-spec(handle_task_vip_label(jiffy:object()) ->
    [{non_neg_integer(), tcp | udp, binary()}]).
handle_task_vip_label(#{<<"key">> := Key, <<"value">> := Value}) ->
    case cowboy_bstr:to_lower(Key) of
        <<"vip_port", Index/binary>> ->
            try binary_to_integer(Index) of
                Idx when Idx < 0 -> [];
                Idx -> handle_task_vip_label(Idx, Value)
            catch error:badarg ->
                []
            end;
        _Key -> []
    end.

-spec(handle_task_vip_label(Idx, Label) -> [{Idx, tcp | udp, Label}]
    when Idx :: non_neg_integer(), Label :: binary()).
handle_task_vip_label(Idx, <<"tcp://", Label/binary>>) ->
    [{Idx, tcp, Label}];
handle_task_vip_label(Idx, <<"udp://", Label/binary>>) ->
    [{Idx, udp, Label}];
handle_task_vip_label(_Idx, _Label) ->
    [].

-spec(handle_task_discovery_ports(jiffy:object(), task()) -> [task_port()]).
handle_task_discovery_ports(TaskObj, Task) ->
    try mget([<<"discovery">>, <<"ports">>, <<"ports">>], TaskObj) of
        Ports ->
            DPorts = lists:flatmap(fun handle_task_discovery_port/1, Ports),
            lists:filter(fun is_discovery_port/1, DPorts)
    catch error:{badkey, _} ->
        maps:get(ports, Task, [])
    end.

-spec(handle_task_discovery_port(jiffy:object()) -> [task_port()]).
handle_task_discovery_port(PortObj) ->
    Name = mget(<<"name">>, PortObj, <<"default">>),
    Port = mget(<<"number">>, PortObj),
    Labels = mget([<<"labels">>, <<"labels">>], PortObj, []),
    VIPLabels = handle_vip_labels(Labels),

    Result = mput(name, Name, #{}),
    Result0 = mput(vip, VIPLabels, Result),

    PortField = handle_port_scope(Labels),
    Result1 = mput(PortField, Port, Result0),

    try handle_protocol(PortObj) of Protocol ->
        [mput(protocol, Protocol, Result1)]
    catch throw:unexpected_protocol ->
        []
    end.

-spec(is_discovery_port(task_port()) -> boolean()).
is_discovery_port(#{port := 0}) ->
    false;
is_discovery_port(_Port) ->
    true.

-spec(handle_vip_labels(jiffy:object()) -> [binary()]).
handle_vip_labels(Labels) when is_list(Labels) ->
    lists:flatmap(fun handle_vip_labels/1, Labels);
handle_vip_labels(#{<<"key">> := <<"VIP", _/binary>>,
                    <<"value">> := VIP}) ->
    [VIP];
handle_vip_labels(#{<<"key">> := <<"vip", _/binary>>,
                    <<"value">> := VIP}) ->
    [VIP];
handle_vip_labels(_Label) ->
    [].

-spec(handle_port_scope(jiffy:object()) -> port | host_port).
handle_port_scope(Labels) ->
    NetworkScopes =
        [ Value || #{<<"key">> := <<"network-scope">>,
                     <<"value">> := Value} <- Labels ],
    case NetworkScopes of
        [<<"container">>] -> port;
        [<<"host">>] -> host_port;
        [] -> port
    end.

-spec(merge_task_ports(Ports, Ports, Ports) -> Ports
    when Ports :: [task_port()]).
merge_task_ports(PortMappings, PortResources, DiscoveryPorts) ->
    merge_task_ports(
        merge_task_ports(PortMappings, PortResources),
        DiscoveryPorts).

-spec(merge_task_ports([task_port()], [task_port()]) -> [task_port()]).
merge_task_ports([], DiscoveryPorts) ->
    DiscoveryPorts;
merge_task_ports(PortMappings, DiscoveryPorts) ->
    lists:foldl(fun (Port, Acc) ->
        merge_task_port(Port, Acc, [])
    end, DiscoveryPorts, PortMappings).

-spec(merge_task_port(P, [P], [P]) -> [P] when P :: task_port()).
merge_task_port(Port, [], Acc) ->
    [Port|Acc];
merge_task_port(PortA, [PortB|Ports], Acc) ->
    case match_task_port(PortA, PortB) of
        true ->
            PortC = merge_ports(PortB, PortA),
            merge_task_port(PortC, [], Acc ++ Ports);
        false ->
            merge_task_port(PortA, Ports, [PortB|Acc])
    end.

-spec(match_task_port(task_port(), task_port()) -> boolean()).
match_task_port(#{protocol := P, port := Key},
                #{protocol := P, port := Key}) ->
    true;
match_task_port(#{protocol := P, host_port := Key},
                #{protocol := P, host_port := Key}) ->
    true;
match_task_port(_PortA, _PortB) ->
    false.

-spec(merge_ports(task_port(), task_port()) -> task_port()).
merge_ports(#{vip := VIPA} = PortA, #{vip := VIPB} = PortB) ->
    Port = maps:merge(PortA, PortB),
    VIP = lists:usort(VIPA ++ VIPB),
    maps:put(vip, VIP, Port);
merge_ports(PortA, PortB) ->
    maps:merge(PortA, PortB).

-spec(merge_host_ports(task(), [task_port()]) -> [task_port()]).
merge_host_ports(#{state := preparing}, Ports) ->
    Ports;
merge_host_ports(#{state := terminal}, Ports) ->
    Ports;
merge_host_ports(#{agent_ip := AgentIP, task_ip := [AgentIP]}, Ports) ->
    PortsMap = merge_host_ports(Ports),
    maps:values(PortsMap);
merge_host_ports(_Task, Ports) ->
    Ports.

-spec(merge_host_ports([task_port()]) -> #{inet:port_number() => [task_port()]}).
merge_host_ports(Ports) ->
    lists:foldl(fun (Port, Acc) ->
        PortA =
            case maps:take(host_port, Port) of
                {K, Port0} -> Port0#{port => K};
                error -> Port
            end,
        Key = {maps:get(protocol, PortA), maps:get(port, PortA)},
        PortB = maps:get(Key, Acc, #{}),
        Acc#{Key => merge_ports(PortA, PortB)}
    end, #{}, Ports).

-spec(handle_task_status(jiffy:object()) -> jiffy:object()).
handle_task_status(#{<<"statuses">> := TaskStatuses}) ->
    [TaskStatus|_TaskStatuses0] =
    lists:sort(fun (#{<<"timestamp">> := A},
                    #{<<"timestamp">> := B}) ->
        A > B
    end, TaskStatuses),
    TaskStatus;
handle_task_status(TaskStatus) ->
    TaskStatus.

%%%===================================================================
%%% Poll Functions
%%%===================================================================

-spec(poll_imp() -> {ok, jiffy:object()} | {error, term()}).
poll_imp() ->
    Begin = erlang:monotonic_time(),
    IsMaster = dcos_net_app:is_master(),
    case dcos_net_mesos:call(#{type => <<"GET_STATE">>}) of
        {ok, Obj, Size1} when IsMaster ->
            prometheus_summary:observe(
                mesos_listener, call_duration_seconds, [],
                erlang:monotonic_time() - Begin),
            prometheus_count:inc(
                mesos_listener, call_received_bytes_total, [],
                Size1),
            {ok, Obj};
        {ok, #{<<"get_state">> := State} = Obj, Size1} ->
            case dcos_net_mesos:call(#{type => <<"GET_AGENT">>}) of
                {ok, #{<<"get_agent">> := Agent}, Size2} ->
                    GetAgents = #{<<"agents">> => [Agent]},
                    State0 = State#{<<"get_agents">> => GetAgents},
                    Obj0 = Obj#{<<"get_state">> => State0},
                    prometheus_summary:observe(
                        mesos_listener, call_duration_seconds, [],
                        erlang:monotonic_time() - Begin),
                    prometheus_counter:inc(
                        mesos_listener, call_received_bytes_total, [],
                        Size1 + Size2),
                    {ok, Obj0};
                {error, Error} ->
                    prometheus_summary:observe(
                        mesos_listener, call_duration_seconds, [],
                        erlang:monotonic_time() - Begin),
                    prometheus_counter:inc(
                       mesos_listener, call_failures_total, [], 1),
                    {error, Error}
            end;
        {error, Error} ->
            prometheus_summary:observe(
                mesos_listener, call_duration_seconds, [],
                erlang:monotonic_time() - Begin),
            prometheus_counter:inc(
                mesos_listener, call_failures_total, [], 1),
            {error, Error}
    end.

-spec(from_state_imp(jiffy:object()) -> #{task_id() => task()}).
from_state_imp(Data) ->
    State = mget(<<"get_state">>, Data, #{}),

    AgentObjs = mget([<<"get_agents">>, <<"agents">>], State, []),
    Agents =
        lists:foldl(fun (AObj, Acc) ->
            #{id := Id, ip := IP} = handle_agent(AObj),
            mput(Id, IP, Acc)
        end, #{}, AgentObjs),

    FrameworkObjs = mget([<<"get_frameworks">>, <<"frameworks">>], State, []),
    Frameworks =
        lists:foldl(fun (FObj, Acc) ->
            #{id := Id, name := Name} = handle_framework(FObj),
            mput(Id, Name, Acc)
        end, #{}, FrameworkObjs),

    TaskObjs = mget([<<"get_tasks">>, <<"launched_tasks">>], State, []),
    TaskObjs0 = mget([<<"get_tasks">>, <<"tasks">>], State, TaskObjs),
    from_state_imp(TaskObjs0, Agents, Frameworks).

-spec(from_state_imp([TaskObj], Agents, Frameworks) -> #{task_id() => task()}
    when TaskObj :: jiffy:object(),
         Agents :: #{binary() => inet:ip4_address()},
         Frameworks :: #{binary() => binary()}).
from_state_imp(TaskObjs, Agents, Frameworks) ->
    lists:foldl(fun (TaskObj, Acc) ->
        FrameworkId = mget([<<"framework_id">>, <<"value">>], TaskObj),
        TaskId = {FrameworkId, mget([<<"task_id">>, <<"value">>], TaskObj)},
        try task(TaskObj, #{}, Agents, Frameworks) of
            #{agent_ip := {id, _}} ->
                Acc;
            #{framework := {id, _}} ->
                Acc;
            Task ->
                mput(TaskId, Task, Acc)
        catch Class:Error ->
            lager:error(
                "Unexpected error with ~s [~p]: ~p",
                [id2bin(TaskId), Class, Error]),
            Acc
        end
    end, #{}, TaskObjs).

%%%===================================================================
%%% Subscribe Functions
%%%===================================================================

-spec(subscribe(pid()) -> {ok, MonRef, Tasks} | {error, atom()}
    when MonRef :: reference(), Tasks :: #{task_id() => task()}).
subscribe(Pid) ->
    MonRef = erlang:monitor(process, Pid),
    Pid ! {subscribe, self(), MonRef},
    receive
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, Reason};
        {error, MonRef, Reason} ->
            erlang:demonitor(MonRef, [flush]),
            {error, Reason};
        {ok, MonRef, Tasks} ->
            {ok, MonRef, Tasks}
    after 5000 ->
        erlang:demonitor(MonRef, [flush]),
        {error, timeout}
    end.

-spec(handle_subscribe(pid(), reference(), state()) -> state()).
handle_subscribe(Pid, Ref, State) ->
    case State of
        [] ->
            Pid ! {error, Ref, init},
            State;
        #state{subs=undefined} ->
            Pid ! {error, Ref, wait},
            State;
        #state{subs=#{Pid := _}} ->
            Pid ! {error, Ref, subscribed},
            State;
        #state{subs=Subs, tasks=T, waiting_tasks=TW} ->
            T0 = maps:without(maps:keys(TW), T),
            Pid ! {ok, Ref, T0},
            _MonRef = erlang:monitor(process, Pid),
            State#state{subs=maps:put(Pid, Ref, Subs)}
    end.

-spec(handle_unsubscribe(pid(), state()) -> state()).
handle_unsubscribe(Pid, #state{subs=Subs}=State) ->
    State#state{subs=maps:remove(Pid, Subs)}.

-spec(notify(task_id(), task(), state()) -> state()).
notify(_TaskId, _Task, #state{subs=undefined}=State) ->
    State;
notify(TaskId, Task, #state{subs=Subs, timeout=Timeout}=State) ->
    Begin = erlang:monotonic_time(),
    try
        maps:fold(fun (Pid, Ref, ok) ->
            Pid ! {task_updated, Ref, TaskId, Task},
            ok
        end, ok, Subs),

        maps:fold(fun (Pid, Ref, St) ->
            receive
                {next, Ref} ->
                    St;
                {'DOWN', _MonRef, process, Pid, _Info} ->
                    handle_unsubscribe(Pid, St)
            after Timeout div 3 ->
                exit(Pid, {?MODULE, timeout}),
                St
            end
        end, State, Subs)
    after
        prometheus_summary:observe(
            mesos_listener, pubsub_duration_seconds,
            [], erlang:monotonic_time() - Begin)
    end.

%%%===================================================================
%%% Maps Functions
%%%===================================================================

-spec(mget([binary()] | binary(), jiffy:object()) -> jiffy:object()).
mget([], Obj) when is_binary(Obj) ->
    binary:copy(Obj);
mget([], Obj) ->
    Obj;
mget([Key | Tail], Obj) ->
    Obj0 = mget(Key, Obj),
    mget(Tail, Obj0);
mget(Key, Obj) ->
    maps:get(Key, Obj).

-spec(mget(Key, jiffy:object(), jiffy:object()) -> jiffy:object()
    when Key :: [binary()] | binary()).
mget(Keys, Obj, Default) ->
    try
        mget(Keys, Obj)
    catch error:{badkey, _Key} ->
        Default
    end.

-spec(mput(A, B, M) -> M
    when A :: term(), B :: term(), M :: #{A => B}).
mput(_Key, [], Map) ->
    Map;
mput(_Key, undefined, Map) ->
    Map;
mput(Key, Value, Map) ->
    maps:put(Key, Value, Map).

-spec(mremove(A, M) -> M
    when A :: term(), B :: term(), M :: #{A => B}).
mremove(Key, Map) ->
    maps:remove(Key, Map).

-spec(mdiff(map(), map()) -> map()).
mdiff(A, B) ->
    maps:fold(fun(K, V, Acc) ->
        case maps:get(K, Acc) of
            V -> maps:remove(K, Acc);
            _ -> Acc
        end
    end, B, A).

%%%===================================================================
%%% Mesos Operator API Client
%%%===================================================================

-spec(handle_init([]) -> state() | []).
handle_init(State0) ->
    Timeout = application:get_env(dcos_net, mesos_reconnect_timeout, 2000),
    case start_stream() of
        {ok, State} ->
            State;
        {error, redirect} ->
            % It's not a leader, don't log anything
            erlang:send_after(Timeout, self(), init),
            State0;
        {error, Error} ->
            lager:error("Couldn't connect to mesos: ~p", [Error]),
            prometheus_counter:inc(mesos_listener, failures_total, [], 1),
            erlang:send_after(Timeout, self(), init),
            State0
    end.

-spec(start_stream() -> {ok, state()} | {error, term()}).
start_stream() ->
    prometheus_boolean:set(mesos_listener, is_leader, [], false),
    Opts = [{stream, {self, once}}],
    Request = #{type => <<"SUBSCRIBE">>},
    case dcos_net_mesos:call(Request, [{timeout, infinity}], Opts) of
        {ok, Ref, Pid} ->
            prometheus_boolean:set(mesos_listener, is_leader, [], true),
            httpc:stream_next(Pid),
            erlang:monitor(process, Pid),
            State = #state{pid=Pid, ref=Ref},
            {ok, handle_heartbeat(State)};
        {error, {http_status, {_HTTPVersion, 307, _StatusStr}, _Data}} ->
            {error, redirect};
        {error, Error} ->
            {error, Error}
    end.

-spec(handle_stream(binary(), state()) ->
    {noreply, state()} | {stop, term(), state()}).
handle_stream(Data, State) ->
    Size = byte_size(Data),
    prometheus_counter:inc(mesos_listener, bytes_total, [], Size),
    case stream(Data, State) of
        {next, State0} ->
            {noreply, State0};
        {next, Obj, State0} ->
            State1 = handle(Obj, State0),
            handle_metrics(State1),
            handle_stream(<<>>, State1);
        {error, Error} ->
            lager:error("Mesos protocol error: ~p", [Error]),
            {stop, Error, State}
    end.

-spec(stream(binary(), State) -> {error, term()} |
    {next, State} | {next, jiffy:object(), State}
        when State :: state()).
stream(Data, #state{pid=Pid, size=undefined, buf=Buf}=State) ->
    Buf0 = <<Buf/binary, Data/binary>>,
    case binary:split(Buf0, <<"\n">>) of
        [SizeBin, Tail] ->
            Size = binary_to_integer(SizeBin),
            State0 = State#state{size=Size, buf= <<>>},
            stream(Tail, State0);
        [Buf0] when byte_size(Buf0) > 12 ->
            {error, {bad_format, Buf0}};
        [Buf0] ->
            httpc:stream_next(Pid),
            {next, State#state{buf=Buf0}}
    end;
stream(Data, #state{pid=Pid, size=Size, buf=Buf}=State) ->
    Buf0 = <<Buf/binary, Data/binary>>,
    case byte_size(Buf0) of
        BufSize when BufSize >= Size ->
            stream_decode(Buf0, Size, State);
        _BufSize ->
            httpc:stream_next(Pid),
            {next, State#state{buf=Buf0}}
    end.

-spec(stream_decode(binary(), integer(), State) -> {error, term()} |
     {next, State} | {next, jiffy:object(), State}
         when State :: state()).
stream_decode(Buf, Size, State) ->
    <<Head:Size/binary, Tail/binary>> = Buf,
    State0 = State#state{size=undefined, buf=Tail},
    prometheus_counter:inc(mesos_listener, messages_total, [], 1),
    try jiffy:decode(Head, [return_maps]) of Obj ->
        {next, Obj, State0}
    catch error:Error ->
        {error, Error}
    end.

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(init_metrics() -> ok).
init_metrics() ->
    init_metrics_mesos_state(),
    init_metrics_mesos_polled_state(),
    init_metrics_mesos_operator_calls(),
    init_metrics_pubsub(),
    init_metrics_received().

init_metrics_mesos_state() ->
    prometheus_gauge:new([
        {registry, mesos_listener},
        {name, agents_total},
        {help, "Total number of agents seem on the Mesos stream."}]),
    prometheus_gauge:new([
        {registry, mesos_listener},
        {name, frameworks_total},
        {help, "Total number of frameworks seen on the Mesos stream."}]),
    prometheus_gauge:new([
        {registry, mesos_listener},
        {name, tasks_total},
        {help, "Total number of tasks seen on the Mesos stream."}]),
    prometheus_gauge:new([
        {registry, mesos_listener},
        {name, waiting_tasks_total},
        {help, "Total number of tasks with no agent/framework information."}]).

init_metrics_mesos_polled_state() ->
    prometheus_counter:new([
       {registry, l4lb},
       {name, poll_failures_total},
       {help, "Total number of poll errors."}]),
    prometheus_summary:new([
       {registry, l4lb},
       {name, poll_process_duration_seconds},
       {help, "Time to process state from mesos."}]),
    prometheus_summary:new([
       {registry, l4lb},
       {name, poll_request_duration_seconds},
       {help, "Time to request state from mesos."}]).

init_metrics_mesos_operator_calls() ->
    prometheus_summary:new([
       {registry, mesos_listener},
       {name, call_duration_seconds},
       {help, "The time spent with calls to the mesos operator API."}]),
    prometheus_counter:new([
       {registry, mesos_listener},
       {name, call_received_bytes_total},
       {help, "Total number of bytes received from mesos operator API."}]),
    prometheus_counter:new([
       {registry, l4lb},
       {name, call_failures_total},
       {help, "Total number of failures calling mesos operator API."}]).


init_metrics_pubsub() ->
    prometheus_summary:new([
        {registry, mesos_listener},
        {name, pubsub_duration_seconds},
        {help, "The time spent notifying all subscribers of mesos_listener."}]).

init_metrics_received() ->
    prometheus_counter:new([
        {registry, mesos_listener},
        {name, bytes_total},
        {help, "Total number of bytes received form the Mesos stream."}]),
    prometheus_counter:new([
        {registry, mesos_listener},
        {name, failures_total},
        {help, "Total number of failures listening to the Mesos stream."}]),
    prometheus_boolean:new([
        {registry, mesos_listener},
        {name, is_leader},
        {help, "True if listening from the leader node."}]),
    prometheus_counter:new([
        {registry, mesos_listener},
        {name, messages_total},
        {help, "Total number of messages received from the Mesos stream."}]).

-spec(handle_metrics(state()) -> state()).
handle_metrics(#state{agents=A, frameworks=F,
        tasks=T, waiting_tasks=WT}=State) ->
    prometheus_gauge:set(
        mesos_listener, tasks_total, [],
        maps:size(T)),
    prometheus_gauge:set(
        mesos_listener, waiting_tasks_total, [],
        maps:size(WT)),
    prometheus_gauge:set(
        mesos_listener, frameworks_total, [],
        maps:size(F)),
    prometheus_gauge:set(
        mesos_listener, agents_total, [],
        maps:size(A)),
    State.
