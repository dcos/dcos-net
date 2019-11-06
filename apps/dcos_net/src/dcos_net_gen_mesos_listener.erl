-module(dcos_net_gen_mesos_listener).
-behavior(gen_server).

% behavior callbacks
-type data() :: term().
-callback handle_info(Info :: term(), data()) ->
    {noreply, data()} | {noreply, data(), boolean()}.
-callback handle_reset(data()) -> ok.
-callback handle_push(data()) -> ok.
-callback handle_tasks(#{task_id() => task()}) -> data().
-callback handle_task_updated(task_id(), task(), data()) ->
    {boolean(), data()}.
-export_type([data/0]).

-include_lib("kernel/include/logger.hrl").

%% API
-export([
    start_link/1,
    start_link/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3,
    handle_cast/2, handle_info/2, handle_continue/2]).

-type task() :: dcos_net_mesos_listener:task().
-type task_id() :: dcos_net_mesos_listener:task_id().

-record(state, {
    ref = undefined :: undefined | reference(),
    push_ref = undefined :: reference() | undefined,
    push_rev = 0 :: non_neg_integer(),
    mod :: module(),
    data :: data()
}).
-type state() :: #state{}.

-spec(start_link(Name, module()) ->
    {ok, pid()} | ignore | {error, Reason :: term()}
        when Name :: {local, atom()} | {global, atom()} | {via, atom(), any()}).
start_link(ServerName, Mod) ->
    gen_server:start_link(ServerName, ?MODULE, [Mod], []).

-spec(start_link(module()) -> {ok, pid()} | ignore | {error, Reason :: term()}).
start_link(Mod) ->
    gen_server:start_link(?MODULE, [Mod], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Mod]) ->
    {ok, #state{mod = Mod}, {continue, init}}.

handle_continue(init, State) ->
    case dcos_net_mesos_listener:subscribe() of
        {ok, Ref} ->
            {noreply, State#state{ref = Ref}};
        {error, timeout} ->
            exit(timeout);
        {error, subscribed} ->
            exit(subscribed);
        {error, _Error} ->
            timer:sleep(100),
            {noreply, State, {continue, init}}
    end;
handle_continue(Request, State) ->
    ?LOG_WARNING("Unexpected info: ~p", [Request]),
    {noreply, State}.

handle_call(Request, _From, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {reply, ok, State}.

handle_cast(Request, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {noreply, State}.

handle_info({{tasks, MTasks}, Ref}, #state{ref = Ref} = State0) ->
    ok = dcos_net_mesos_listener:next(Ref),
    {noreply, handle_tasks(MTasks, State0)};
handle_info({{task_updated, TaskId, Task}, Ref}, #state{ref = Ref} = State) ->
    ok = dcos_net_mesos_listener:next(Ref),
    {noreply, handle_task_updated(TaskId, Task, State)};
handle_info({eos, Ref}, #state{ref = Ref} = State) ->
    ok = dcos_net_mesos_listener:next(Ref),
    {noreply, reset_state(State)};
handle_info({'DOWN', Ref, process, _Pid, Info}, #state{ref = Ref} = State) ->
    {stop, Info, State};
handle_info({timeout, _Ref, init}, #state{ref = undefined} = State) ->
    {noreply, State, {continue, init}};
handle_info({timeout, Ref, {push, Rev}},
        #state{push_ref = Ref} = State) ->
    {noreply, handle_push(Rev, State), hibernate};
handle_info(Info, #state{mod = Mod, data = Data} = State) ->
    case Mod:handle_info(Info, Data) of
        {noreply, Data0} ->
            {noreply, State#state{data = Data0}};
        {noreply, Data0, Updated} ->
            {noreply, maybe_handle_push(Updated, State#state{data = Data0})}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(reset_state(state()) -> state()).
reset_state(#state{mod = Mod, data = Data,
        ref = Ref, push_ref = PushZoneRef}) ->
    case PushZoneRef of
        undefined-> ok;
        _ -> erlang:cancel_timer(PushZoneRef)
    end,
    ok = Mod:handle_reset(Data),
    #state{ref = Ref}.

%%%===================================================================
%%% Tasks functions
%%%===================================================================

-spec(handle_tasks(#{task_id() => task()}, state()) -> state()).
handle_tasks(Tasks, #state{mod = Mod} = State) ->
    Data = Mod:handle_tasks(Tasks),
    handle_push(State#state{data = Data}).

-spec(handle_task_updated(task_id(), task(), state()) -> state()).
handle_task_updated(TaskId, Task, #state{mod = Mod, data = Data} = State) ->
    {Updated, Data0} = Mod:handle_task_updated(TaskId, Task, Data),
    maybe_handle_push(Updated, State#state{data = Data0}).

%%%===================================================================
%%% Lashup functions
%%%===================================================================

-spec(maybe_handle_push(boolean(), state()) -> state()).
maybe_handle_push(false, State) ->
    State;
maybe_handle_push(true, State) ->
    handle_push(State).

-spec(handle_push(non_neg_integer(), state()) -> state()).
handle_push(RevA, #state{push_rev = RevB} = State) ->
    maybe_handle_push(RevA < RevB, State#state{push_ref=undefined}).

-spec(handle_push(state()) -> state()).
handle_push(#state{push_ref = undefined, push_rev = Rev,
        mod = Mod, data = Data} = State) ->
    % NOTE: push data to lashup 1 time per second
    ok = Mod:handle_push(Data),
    Rev0 = Rev + 1,
    Ref0 = start_push_timer(Rev0),
    State#state{push_ref = Ref0, push_rev = Rev0};
handle_push(#state{push_rev = Rev} = State) ->
    State#state{push_rev = Rev + 1}.

-spec(start_push_timer(Rev :: non_neg_integer()) -> reference()).
start_push_timer(Rev) ->
    Timeout = application:get_env(dcos_net, push_timeout, 1000),
    erlang:start_timer(Timeout, self(), {push, Rev}).
