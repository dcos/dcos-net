-module(dcos_net_mesos_state).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-record(state, {
    pid :: pid(),
    ref :: reference(),
    size = undefined :: pos_integer() | undefined,
    buf = <<>> :: binary(),
    timeout = 15000 :: timeout(),
    timeout_ref = make_ref() :: reference()
}).

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
            io:format("~p~n", [Obj]),
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
%%% Internal functions
%%%===================================================================

-spec(handle(jiffy:object(), #state{}) -> #state{}).
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

handle(subscribed, Obj, State) ->
    Timeout = maps:get(<<"heartbeat_interval_seconds">>, Obj),
    Timeout0 = erlang:trunc(Timeout * 1000),
    State0 = State#state{timeout = Timeout0},
    handle(heartbeat, #{}, State0);

handle(heartbeat, _Obj, #state{timeout = T, timeout_ref = TRef}=State) ->
    TRef0 = erlang:start_timer(3 * T, self(), httpc),
    _ = erlang:cancel_timer(TRef),
    State#state{timeout_ref=TRef0};

handle(task_added, _Obj, State) ->
    State;

handle(task_updated, _Obj, State) ->
    State;

handle(framework_added, _Obj, State) ->
    State;

handle(framework_updated, _Obj, State) ->
    State;

handle(framework_removed, _Obj, State) ->
    State;

handle(agent_added, _Obj, State) ->
    State;

handle(agent_removed, _Obj, State) ->
    State.

%%%===================================================================
%%% Mesos Operator API Client
%%%===================================================================

-spec(subscribe() -> {ok, #state{}} | {error, term()}).
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
        when State :: #state{}).
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
