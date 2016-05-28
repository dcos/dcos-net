%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 12:58 PM
%%%-------------------------------------------------------------------
-module(dcos_dns_poll_fsm).
-author("sdhillon").

-behaviour(gen_fsm).

%% API
-export([start_link/0, status/0]).

%% gen_fsm callbacks
-export([init/1,
    leader/2,
    leader/3,
    not_leader/2,
    not_leader/3,
    handle_event/3,
    handle_sync_event/4,
    handle_info/3,
    terminate/3,
    code_change/4]).

-define(SERVER, ?MODULE).

-define(MASTERS_KEY, {masters, riak_dt_orswot}).
-define(MAX_CONSECUTIVE_POLLS, 10).

-record(state, {
    master_list = [] :: node(),
    consecutive_polls = 0 :: non_neg_integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

status() ->
    gen_fsm:sync_send_all_state_event(?SERVER, status).

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() -> {ok, pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, StateName :: atom(), StateData :: #state{}} |
    {ok, StateName :: atom(), StateData :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    gen_fsm:start_timer(master_period(), try_master),
    gen_fsm:start_timer(poll_period(), poll),
    {ok, not_leader, #state{}}.


%% See if I can become master
not_leader({timeout, _Ref, poll}, State) ->
    gen_fsm:start_timer(poll_period(), poll),
    {next_state, not_leader, State};
not_leader({timeout, _Ref, try_master}, State0) ->
    {NextStateName, State1} = try_master(State0),
    gen_fsm:start_timer(master_period(), try_master),
    {next_state, NextStateName, State1}.


not_leader(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, not_leader, State}.

%% Step down from being master, but try to get it back immediately.
%% There are situations when global can become inconsistent
leader({timeout, _Ref, try_master}, State0 = #state{consecutive_polls = CP, master_list = ML})
        when CP > ?MAX_CONSECUTIVE_POLLS ->
    gen_fsm:start_timer(1, try_master),
    global:del_lock({?MODULE, self()}, ML),
    State1 = State0#state{consecutive_polls = 0},
    {next_state, not_leader, State1};
leader({timeout, _Ref, try_master}, State0 = #state{master_list = MasterList0}) ->
    MasterList1 = MasterList0,
    gen_fsm:start_timer(master_period(), try_master),
    case masters() of
        MasterList1 ->
            {next_state, leader, State0};
        NewMasterList ->
            global:del_lock({?MODULE, self()}, MasterList0),
            State1 = State0#state{master_list = NewMasterList},
            {next_state, not_leader, State1}
    end;

leader({timeout, _Ref, poll}, State0 = #state{consecutive_polls = CP, master_list = MasterList0}) ->
    State1 = State0#state{consecutive_polls = CP + 1},
    Rep =
        case poll(State1) of
            {ok, State2} ->
                {next_state, leader, State2};
            {error, _} ->
                global:del_lock({?MODULE, self()}, MasterList0),
                {next_state, not_leader, State1}
        end,
    gen_fsm:start_timer(poll_period(), poll),
    Rep.


leader(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, not_leader, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_event(Event :: term(), StateName :: atom(),
    StateData :: #state{}) ->
    {next_state, NextStateName :: atom(), NewStateData :: #state{}} |
    {next_state, NextStateName :: atom(), NewStateData :: #state{},
        timeout() | hibernate} |
    {stop, Reason :: term(), NewStateData :: #state{}}).
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_sync_event(Event :: term(), From :: {pid(), Tag :: term()},
    StateName :: atom(), StateData :: term()) ->
    {reply, Reply :: term(), NextStateName :: atom(), NewStateData :: term()} |
    {reply, Reply :: term(), NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {next_state, NextStateName :: atom(), NewStateData :: term()} |
    {next_state, NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewStateData :: term()} |
    {stop, Reason :: term(), NewStateData :: term()}).

handle_sync_event(status, _From, StateName, State = #state{master_list = ML, consecutive_polls = CPs}) ->
    Status = #{
        state => StateName,
        masters => ML,
        poll_count => CPs
    },
    {reply, {ok, Status}, StateName, State};
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: term(), StateName :: atom(),
    StateData :: term()) ->
    {next_state, NextStateName :: atom(), NewStateData :: term()} |
    {next_state, NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {stop, Reason :: normal | term(), NewStateData :: term()}).
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: normal | shutdown | {shutdown, term()}
| term(), StateName :: atom(), StateData :: term()) -> term()).
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, StateName :: atom(),
    StateData :: #state{}, Extra :: term()) ->
    {ok, NextStateName :: atom(), NewStateData :: #state{}}).
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

poll_period() ->
    application:get_env(dcos_dns, poll_period, 30000).

master_period() ->
    application:get_env(dcos_dns, master_period, 15000).

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

%% Should only be called in not_leader
try_master(State0) ->
    Masters = masters(),
    State1 = State0#state{master_list = Masters},
    case ordsets:is_element(node(), Masters) of
        true ->
            try_master1(State1);
        false ->
            {not_leader, State1}
    end.

try_master1(State = #state{master_list = Masters}) ->
    ExemptNodes0 = application:get_env(lashup, exempt_nodes, []),
    ExemptNodes1 = lists:usort(ExemptNodes0 ++ Masters),
    application:set_env(lashup, exempt_nodes, ExemptNodes1),
    %% The reason we don't immediately return is we want to schedule the try_master event
    %% But, we must wait for it to return from global, otherwise we can get into a tight loop
    LockResult = global:set_lock({?MODULE, self()}, Masters, 1),
    case LockResult of
        true ->
            {leader, State};
        false ->
            {not_leader, State}
    end.

poll(State0) ->
    lager:info("Navstar DNS polling"),
    IP = inet:ntoa(mesos_state:ip()),
    URI = lists:flatten(io_lib:format("http://~s:5050/state", [IP])),
    case mesos_state_client:poll(URI) of
        {ok, _MAS0} ->
            {ok, State0};
        Error ->
            lager:warning("Could not poll mesos state: ~p", [Error]),
            {error, Error}
    end.
