-module(dcos_net_mesos_state).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-type task_id() :: binary().
-type task() :: #{
    name => binary(),
    state => binary(),
    agent => binary() | {id, binary()},
    framework => binary() | {id, binary()}
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
    waiting_tasks = #{} :: #{task_id() => true}
}).

-type state() :: #state{}.

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! init,
    {ok, []}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, []) ->
    case subscribe() of
        {ok, State} ->
            {noreply, State};
        {error, redirect} ->
            % It's not a leader, don't log annything
            timer:sleep(100),
            self() ! init,
            {noreply, []};
        {error, Error} ->
            lager:error("Couldn't connect to mesos: ~p", [Error]),
            timer:sleep(100),
            self() ! init,
            {noreply, []}
    end;
handle_info({http, {Ref, stream, Data}}, #state{ref=Ref}=State) ->
    case stream(Data, State) of
        {next, State0} ->
            {noreply, State0};
        {next, Obj, State0} ->
            State1 = handle(Obj, State0),
            handle_info({http, {Ref, stream, <<>>}}, State1);
        {error, Error} ->
            lager:error("Mesos protocol error: ~p", [Error]),
            {stop, Error, State}
    end;
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
    Obj0 = maps:get(<<"subscribed">>, Obj),
    handle(subscribed, Obj0, State);
handle(#{<<"type">> := <<"HEARTBEAT">>}, State) ->
    handle(heartbeat, #{}, State);
handle(#{<<"type">> := <<"TASK_ADDED">>} = Obj, State) ->
    Obj0 = maps:get(<<"task_added">>, Obj),
    handle(task_added, Obj0, State);
handle(#{<<"type">> := <<"TASK_UPDATED">>} = Obj, State) ->
    Obj0 = maps:get(<<"task_updated">>, Obj),
    handle(task_updated, Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_ADDED">>} = Obj, State) ->
    Obj0 = maps:get(<<"framework_added">>, Obj),
    handle(framework_added, Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_UPDATED">>} = Obj, State) ->
    Obj0 = maps:get(<<"framework_updated">>, Obj),
    handle(framework_updated, Obj0, State);
handle(#{<<"type">> := <<"FRAMEWORK_REMOVED">>} = Obj, State) ->
    Obj0 = maps:get(<<"framework_removed">>, Obj),
    handle(framework_removed, Obj0, State);
handle(#{<<"type">> := <<"AGENT_ADDED">>} = Obj, State) ->
    Obj0 = maps:get(<<"agent_added">>, Obj),
    handle(agent_added, Obj0, State);
handle(#{<<"type">> := <<"AGENT_REMOVED">>} = Obj, State) ->
    Obj0 = maps:get(<<"agent_removed">>, Obj),
    handle(agent_removed, Obj0, State);
handle(Obj, State) ->
    lager:error("Unexpected mesos message type: ~p", [Obj]),
    State.

-spec(handle(atom(), jiffy:object(), state()) -> state()).
handle(subscribed, Obj, State) ->
    Timeout = maps:get(<<"heartbeat_interval_seconds">>, Obj),
    Timeout0 = erlang:trunc(Timeout * 1000),
    State0 = State#state{timeout = Timeout0},

    MState = mget(<<"get_state">>, Obj, #{}),

    Agents = mget([<<"get_agents">>, <<"agents">>], MState, []),
    State1 =
        lists:foldl(fun (Agent, St) ->
            handle(agent_added, #{<<"agent">> => Agent}, St)
        end, State0, Agents),

    Frameworks = mget([<<"get_frameworks">>, <<"frameworks">>], MState, []),
    State2 =
        lists:foldl(fun (Framework, St) ->
            handle(framework_updated, #{<<"framework">> => Framework}, St)
        end, State1, Frameworks),

    Tasks = mget([<<"get_tasks">>, <<"tasks">>], MState, []),
    State3 =
        lists:foldl(fun (Task, St) ->
            handle_task(Task, St)
        end, State2, Tasks),

    erlang:garbage_collect(),
    handle(heartbeat, #{}, State3);

handle(heartbeat, _Obj, #state{timeout = T, timeout_ref = TRef}=State) ->
    TRef0 = erlang:start_timer(3 * T, self(), httpc),
    _ = erlang:cancel_timer(TRef),
    State#state{timeout_ref=TRef0};

handle(task_added, Obj, State) ->
    Task = mget(<<"task">>, Obj),
    handle_task(Task, State);

handle(task_updated, Obj, State) ->
    Task = mget(<<"status">>, Obj),
    FrameworkId = mget(<<"framework_id">>, Obj),
    Task0 = mput(<<"framework_id">>, FrameworkId, Task),
    handle_task(Task0, State);

handle(framework_added, Obj, State) ->
    handle(framework_updated, Obj, State);

handle(framework_updated, Obj, #state{frameworks=F}=State) ->
    Info = mget([<<"framework">>, <<"framework_info">>], Obj),
    Id = mget([<<"id">>, <<"value">>], Info),
    Name = mget(<<"name">>, Info, undefined),

    lager:notice("Framework ~s added, ~s", [Id, Name]),
    State0 = State#state{frameworks=mput(Id, Name, F)},
    handle_waiting_tasks({framework, Id}, Name, State0);

handle(framework_removed, Obj, #state{frameworks=F}=State) ->
    Id = mget([<<"framework_info">>, <<"id">>, <<"value">>], Obj),
    lager:notice("Framework ~s removed", [Id]),
    State#state{frameworks=mremove(Id, F)};

handle(agent_added, Obj, #state{agents=A}=State) ->
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
    handle_waiting_tasks({agent, Id}, Host, State0);

handle(agent_removed, Obj, #state{agents=A}=State) ->
    Id = mget([<<"agent_id">>, <<"value">>], Obj),
    lager:notice("Agent ~s removed", [Id]),
    State#state{agents=mremove(Id, A)}.

%%%===================================================================
%%% Handle task functions
%%%===================================================================

% NOTE: See comments for enum TaskState (#L2170-L2230) in
% https://github.com/apache/mesos/blob/1.5.0/include/mesos/v1/mesos.proto
-define(IS_TERMINAL(S),
    S =:= <<"TASK_FINISHED">> orelse
    S =:= <<"TASK_FAILED">> orelse
    S =:= <<"TASK_KILLED">> orelse
    S =:= <<"TASK_ERROR">> orelse
    S =:= <<"TASK_DROPPED">> orelse
    S =:= <<"TASK_GONE">>
).

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
        state => {mget, <<"state">>},
        framework => {value, Framework},
        agent => {value, Agent},
        name => {mget, <<"name">>}
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

    lager:notice("Task ~s updated ~p", [TaskId, mdiff(Task, Task0)]),
    add_task(TaskId, Task0, State).

-spec(add_task(task_id(), task(), state()) -> state()).
add_task(TaskId, #{state := TaskState}, #state{tasks=T, waiting_tasks=TW}=State)
        when ?IS_TERMINAL(TaskState) ->
    State#state{
        tasks=mremove(TaskId, T),
        waiting_tasks=mremove(TaskId, TW)};
add_task(TaskId, Task, #state{tasks=T, waiting_tasks=TW}=State) ->
    % NOTE: you can get task info before you get agent or framework
    TW0 =
        case Task of
            #{agent := {id, _Id}} ->
                mput(TaskId, true, TW);
            #{framework := {id, _Id}} ->
                mput(TaskId, true, TW);
            _Task ->
                mremove(TaskId, TW)
        end,
    State#state{
        tasks=mput(TaskId, Task, T),
        waiting_tasks=TW0}.

-spec(handle_waiting_tasks(
    {agent | framework, binary()},
    term(), state()) -> state()).
handle_waiting_tasks({Key, Id}, Value, #state{waiting_tasks=TW}=State) ->
    maps:fold(fun(TaskId, true, #state{tasks=T}=Acc) ->
        Task = maps:get(TaskId, T),
        case maps:get(Key, Task) of
            {id, Id} ->
                lager:notice("Task ~s updated, ~p", [TaskId, #{Key => Value}]),
                add_task(TaskId, mput(Key, Value, Task), Acc);
            _KValue ->
                Acc
        end
    end, State, TW).

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

-spec(mput(A, B | undefined, M) -> M
    when A :: term(), B :: term(), M :: #{A => B}).
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

-spec(subscribe() -> {ok, state()} | {error, term()}).
subscribe() ->
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
            monitor(process, Pid),
            {ok, #state{pid=Pid, ref=Ref}}
    after 5000 ->
        ok = httpc:cancel_request(Ref),
        {error, timeout}
    end.

-spec(stream(binary(), State) -> {error, term()} |
    {next, State} | {next, binary(), State}
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
