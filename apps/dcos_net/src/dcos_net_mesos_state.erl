-module(dcos_net_mesos_state).

%% API
-export([
    start_link/0,
    subscribe/0,
    is_leader/0,
    next/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-export_type([task_id/0, task/0, task_state/0, task_port/0]).

-type task_id() :: binary().
-type task() :: #{
    name => binary(),
    framework => binary() | {id, binary()},
    agent_ip => inet:ip4_address() | {id, binary()},
    task_ip => [inet:ip_address()],
    state => task_state(),
    ports => [task_port()]
}.
-type task_state() :: true | running | {running, boolean()} | false.
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
    frameworks = #{} :: #{binary() => binary()},
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

terminate(_Reason, _State) ->
    ok.

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
    handle_task(Task0, State).

-spec(handle_framework_added(jiffy:object(), state()) -> state()).
handle_framework_added(Obj, State) ->
    handle_framework_updated(Obj, State).

-spec(handle_framework_updated(jiffy:object(), state()) -> state()).
handle_framework_updated(Obj, #state{frameworks=F}=State) ->
    Info = mget([<<"framework">>, <<"framework_info">>], Obj),
    Id = mget([<<"id">>, <<"value">>], Info),
    Name = mget(<<"name">>, Info, undefined),

    lager:notice("Framework ~s added, ~s", [Id, Name]),
    State0 = State#state{frameworks=mput(Id, Name, F)},
    handle_waiting_tasks(framework, Id, Name, State0).

-spec(handle_framework_removed(jiffy:object(), state()) -> state()).
handle_framework_removed(Obj, #state{frameworks=F}=State) ->
    Id = mget([<<"framework_info">>, <<"id">>, <<"value">>], Obj),
    lager:notice("Framework ~s removed", [Id]),
    State#state{frameworks=mremove(Id, F)}.

-spec(handle_agent_added(jiffy:object(), state()) -> state()).
handle_agent_added(Obj, #state{agents=A}=State) ->
    Info = mget([<<"agent">>, <<"agent_info">>], Obj),
    Id = mget([<<"id">>, <<"value">>], Info),
    {ok, Host} =
        try mget(<<"hostname">>, Info) of Hostname ->
            lager:notice("Agent ~s added, ~s", [Id, Hostname]),
            Hostname0 = binary_to_list(Hostname),
            inet:parse_ipv4strict_address(Hostname0)
        catch error:{badkey, _} ->
            lager:notice("Agent ~s added", [Id]),
            {ok, undefined}
        end,

    State0 = State#state{agents=mput(Id, Host, A)},
    handle_waiting_tasks(agent_ip, Id, Host, State0).

-spec(handle_agent_removed(jiffy:object(), state()) -> state()).
handle_agent_removed(Obj, #state{agents=A}=State) ->
    Id = mget([<<"agent_id">>, <<"value">>], Obj),
    lager:notice("Agent ~s removed", [Id]),
    State#state{agents=mremove(Id, A)}.

%%%===================================================================
%%% Handle task functions
%%%===================================================================

-spec(handle_task(jiffy:object(), state()) -> state()).
handle_task(TaskObj, #state{tasks=T}=State) ->
    TaskId = mget([<<"task_id">>, <<"value">>], TaskObj),
    Task = maps:get(TaskId, T, #{}),
    handle_task(TaskId, TaskObj, Task, State).

-spec(handle_task(
    task_id(), jiffy:object(),
    task(), state()) -> state()).
handle_task(TaskId, TaskObj, Task,
        #state{frameworks=F, agents=A}=State) ->
    AgentId = mget([<<"agent_id">>, <<"value">>], TaskObj),
    Agent = mget(AgentId, A, {id, AgentId}),

    FrameworkId = mget([<<"framework_id">>, <<"value">>], TaskObj),
    Framework = mget(FrameworkId, F, {id, FrameworkId}),

    Fields = #{
        name => {mget, <<"name">>},
        framework => {value, Framework},
        agent_ip => {value, Agent},
        task_ip => fun handle_task_ip/2,
        state => fun handle_task_state/2,
        ports => fun handle_task_ports/2
    },
    Task0 =
        maps:fold(
            fun (Key, {value, Value}, Acc) ->
                    mput(Key, Value, Acc);
                (Key, Fun, Acc) when is_function(Fun) ->
                    Value = Fun(TaskObj, Acc),
                    mput(Key, Value, Acc);
                (Key, {mget, Path}, Acc) ->
                    Value = mget(Path, TaskObj, undefined),
                    mput(Key, Value, Acc)
            end, Task, Fields),

    add_task(TaskId, Task, Task0, State).

-spec(add_task(task_id(), task(), task(), state()) -> state()).
add_task(TaskId, TaskPrev, TaskNew, State) ->
    case mdiff(TaskPrev, TaskNew) of
        MDiff when map_size(MDiff) =:= 0 ->
            State;
        MDiff ->
            lager:notice("Task ~s updated with ~p", [TaskId, MDiff]),
            add_task(TaskId, TaskNew, State)
    end.

-spec(add_task(task_id(), task(), state()) -> state()).
add_task(TaskId, #{state := false} = Task, #state{
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
                lager:notice("Task ~s updated with ~p", [TaskId, #{Key => Value}]),
                add_task(TaskId, mput(Key, Value, Task), Acc);
            _KValue ->
                Acc
        end
    end, State, TW).

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
            false;
        <<"TASK_RUNNING">> ->
            Status = handle_task_status(TaskObj),
            case mget(<<"healthy">>, Status, undefined) of
                undefined -> running;
                Healthy ->
                    % NOTE: it doesn't work, see CORE-1458
                    {running, Healthy}
            end;
        _TaskState ->
            true
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
    DiscoveryPorts = handle_task_discovery_ports(TaskObj, Task),
    merge_task_ports(PortMappings, DiscoveryPorts).

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
    lists:map(fun handle_port_mappings/1, PortMappings);
handle_port_mappings(PortMapping) ->
    Protocol = handle_protocol(PortMapping),
    Port = mget(<<"container_port">>, PortMapping),
    HostPort = mget(<<"host_port">>, PortMapping),
    #{protocol => Protocol, port => Port, host_port => HostPort}.

-spec(handle_protocol(jiffy:object()) -> tcp | udp).
handle_protocol(Obj) ->
    Protocol = mget(<<"protocol">>, Obj),
    case cowboy_bstr:to_lower(Protocol) of
        <<"tcp">> -> tcp;
        <<"udp">> -> udp
    end.

-spec(handle_task_discovery_ports(jiffy:object(), task()) -> [task_port()]).
handle_task_discovery_ports(TaskObj, Task) ->
    try mget([<<"discovery">>, <<"ports">>, <<"ports">>], TaskObj) of
        Ports ->
            DPorts = lists:map(fun handle_task_discovery_port/1, Ports),
            lists:filter(fun is_discovery_port/1, DPorts)
    catch error:{badkey, _} ->
        maps:get(ports, Task, [])
    end.

-spec(handle_task_discovery_port(jiffy:object()) -> task_port()).
handle_task_discovery_port(PortObj) ->
    Name = mget(<<"name">>, PortObj, <<"default">>),
    Protocol = handle_protocol(PortObj),
    Port = mget(<<"number">>, PortObj),
    Labels = mget([<<"labels">>, <<"labels">>], PortObj, []),
    VIPLabels = handle_vip_labels(Labels),

    Result = #{protocol => Protocol},
    Result0 = mput(name, Name, Result),
    Result1 = mput(vip, VIPLabels, Result0),

    PortField = handle_port_scope(Labels),
    mput(PortField, Port, Result1).

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

-spec(merge_task_ports([task_port()], [task_port()]) -> [task_port()]).
merge_task_ports([], DiscoveryPorts) ->
    DiscoveryPorts;
merge_task_ports(PortMappings, DiscoveryPorts) ->
    Ports =
        maps:from_list([ begin
            A = maps:get(protocol, TaskPort),
            B = maps:get(port, TaskPort, undefined),
            C = maps:get(host_port, TaskPort, undefined),
            {{A, B, C}, TaskPort}
        end || TaskPort <- DiscoveryPorts ]),
    Ports0 =
        lists:foldl(fun (TaskPort, Acc) ->
            A = maps:get(protocol, TaskPort),
            B = maps:get(port, TaskPort, undefined),
            C = maps:get(host_port, TaskPort, undefined),
            KeyA = {A, B, undefined},
            KeyB = {A, undefined, C},
            KeyC = {A, B, C},
            case mfind([KeyA, KeyB, KeyC], Acc) of
                {ok, Key, TP} ->
                    TP0 = maps:merge(TP, TaskPort),
                    maps:put(Key, TP0, Acc);
                error ->
                    maps:put(KeyC, TaskPort, Acc)
            end
        end, Ports, PortMappings),
    maps:values(Ports0).

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
    end, State, Subs).

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

-spec(mfind([Key], #{Key => Value}) -> {ok, Key, Value} | error
    when Key :: term(), Value :: term()).
mfind(Keys, Map) ->
    MapW = maps:with(Keys, Map),
    case maps:to_list(MapW) of
        [{Key, Value}] -> {ok, Key, Value};
        [] -> error
    end.

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
            erlang:send_after(Timeout, self(), init),
            State0
    end.

-spec(start_stream() -> {ok, state()} | {error, term()}).
start_stream() ->
    Body = jiffy:encode(#{type => <<"SUBSCRIBE">>}),
    ContentType = "application/json",
    Request = {"/api/v1", [], ContentType, Body},
    {ok, Ref} =
        dcos_net_mesos:request(
            post, Request, [{timeout, infinity}],
            [{sync, false}, {stream, {self, once}}]),
    receive
        {http, {Ref, {{_HTTPVersion, 307, _StatusStr}, _Headers, _Body}}} ->
            {error, redirect};
        {http, {Ref, {{_HTTPVersion, Status, _StatusStr}, _Headers, _Body}}} ->
            {error, {http_status, Status}};
        {http, {Ref, {error, Error}}} ->
            {error, Error};
        {http, {Ref, stream_start, _Headers, Pid}} ->
            httpc:stream_next(Pid),
            erlang:monitor(process, Pid),
            State = #state{pid=Pid, ref=Ref},
            {ok, handle_heartbeat(State)}
    after 5000 ->
        ok = httpc:cancel_request(Ref),
        {error, timeout}
    end.

-spec(handle_stream(binary(), state()) ->
    {noreply, state()} | {stop, term(), state()}).
handle_stream(Data, State) ->
    case stream(Data, State) of
        {next, State0} ->
            {noreply, State0};
        {next, Obj, State0} ->
            State1 = handle(Obj, State0),
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
            <<Head:Size/binary, Tail/binary>> = Buf0,
            State0 = State#state{size=undefined, buf=Tail},
            try jiffy:decode(Head, [return_maps]) of Obj ->
                {next, Obj, State0}
            catch error:Error ->
                {error, Error}
            end;
        _BufSize ->
            httpc:stream_next(Pid),
            {next, State#state{buf=Buf0}}
    end.
