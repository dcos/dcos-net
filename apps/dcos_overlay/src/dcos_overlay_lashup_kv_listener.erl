%%%-------------------------------------------------------------------
%%% @author dgoel
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 11 OCT 2016 9:27 PM
%%%-------------------------------------------------------------------
-module(dcos_overlay_lashup_kv_listener).
-author("dgoel").

-behaviour(gen_statem).

%% API
-export([start_link/0]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3, code_change/4]).

%% state API
-export([unconfigured/3, configuring/3, batching/3, reapplying/3]).

-define(SERVER, ?MODULE).
-define(HEAPSIZE, 100). %% In MB
-define(KILL_TIMER, 300000). %% 5 min
-define(BATCH_TIMEOUT, 5000). %% 5 secs
-define(REAPPLY_TIMEOUT, 300000). %% 5 min

-include_lib("stdlib/include/ms_transform.hrl").

-type config() :: orddict:orddict(term(), term()).

-record(data, {
    ref :: reference(),
    pid :: undefined | pid(),
    config = orddict:new() :: config(),
    num_req = 0 :: non_neg_integer(),
    num_res = 0 :: non_neg_integer(),
    kill_timer :: undefined | timer:tref()
}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State, Data} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: atom(), Data :: #data{}} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    MaxHeapSizeInWords = (?HEAPSIZE bsl 20) div erlang:system_info(wordsize), %%100 MB
    process_flag(message_queue_data, on_heap),
    process_flag(max_heap_size, MaxHeapSizeInWords),
    MatchSpec = mk_key_matchspec(),
    {ok, Ref} = lashup_kv_events_helper:start_link(MatchSpec),
    {ok, unconfigured, #data{ref = Ref}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec callback_mode() -> handle_event_function | state_functions
%% @end
%%--------------------------------------------------------------------
-spec(callback_mode() -> handle_event_function | state_functions).
callback_mode() -> 
    state_functions.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_statem terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State, Data) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: atom(), Data :: #data{}) -> term()).
terminate(_Reason, _State, _Data) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, OldState, OldData, Extra) -> {state_functions, NewState, NewData}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, OldState :: atom(),
    OldData :: #data{}, Extra :: term()) ->
    {ok, NewState :: atom(), NewData :: #data{}}).
code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.

%%-----------------------------------------------------------------------------------------------------
%% State transition
%%----------------------------------------------------------------------------------------------------- 
%%                                                              lashup_event
%%                                                               +------+
%%                                                               |      |
%%  +--------------+              +-------------+ lashup event +-+------+-+               +------------+
%%  |              |              |             +      or      |          |               |            |
%%  |              | lashup_event |             |    timeout1  |          |    reapply    |            |
%%  | unconfigured +------------> | configuring +------------> | batching +-------------> | reapplying |
%%  |              |              |             | <------------+          |               |            |
%%  |              |              |             |    timeout2  |          |               |            |
%%  |              |              |             |              |          |               |            |
%%  +--------------+              +-------------+              +----------+               +------------+
%%                                       |<------------------------------------------------------|
%%------------------------------------------------------------------------------------------------------

unconfigured(info, LashupEvent = {lashup_kv_events, #{key := OverlayKey, value := Value}}, StateData0) ->
    StateData1 = handle_lashup_event(LashupEvent, StateData0),
    {ok, Timer} = timer:kill_after(?KILL_TIMER),
    EventContent = #{key => OverlayKey, value => Value},
    StateData2 = StateData1#data{kill_timer = Timer, num_req = 1, num_res = 0},
    {next_state, configuring, StateData2, {next_event, internal, EventContent}}.

configuring(internal, Config, _StateData) ->
    lager:debug("Applying configuration: ~p", [Config]),
    dcos_overlay_configure:start_link(Config),
    keep_state_and_data;
configuring(info, {dcos_overlay_configure, applied_config, AppliedConfig}, StateData0) ->
    lager:debug("Done applying configuration: ~p", [AppliedConfig]),
    StateData1 = maybe_update_state(StateData0),
    next_state_transition(StateData1);
configuring(info, _EventContent, _StateData) ->
    {keep_state_and_data, postpone}.
            
batching(info, LashupEvent, StateData0) ->
    StateData1 = handle_lashup_event(LashupEvent, StateData0),
    {keep_state, StateData1, {timeout, ?BATCH_TIMEOUT, do_configure}};
batching(timeout, do_configure, StateData0 = #data{config = Config}) ->
    {StateData1, Actions} = next_state_and_actions(Config, StateData0),
    {next_state, configuring, StateData1, Actions};
batching(timeout, do_reapply, StateData) ->
    {next_state , reapplying, StateData, {next_event, internal, reapply}}.

reapplying(internal, reapply, StateData0) ->
    Config = fetch_lashup_config(),
    {StateData1, Actions} = next_state_and_actions(Config, StateData0),
    {next_state, configuring, StateData1, Actions}.

%% private API

mk_key_matchspec() ->
    ets:fun2ms(fun({[navstar, overlay, '_']}) -> true end).

-spec(handle_lashup_event(LashupEvent :: tuple(), #data{}) -> #data{}).
handle_lashup_event({lashup_kv_events, #{type := ingest_new, key := OverlayKey, value := NewOverlayConfig, ref := Ref}},
             StateData = #data{ref = Ref}) ->
    handle_lashup_event2(OverlayKey, NewOverlayConfig, [], StateData);
handle_lashup_event({lashup_kv_events, #{type := ingest_update, key := OverlayKey, value := NewOverlayConfig,
             old_value := OldOverlayConfig, ref := Ref}}, StateData = #data{ref = Ref}) ->
    handle_lashup_event2(OverlayKey, NewOverlayConfig, OldOverlayConfig, StateData).

-spec(handle_lashup_event2(Key :: list(), NewOverlayConfig :: list(), OldOverlayConfig :: list(), #data{}) -> #data{}).
handle_lashup_event2(OverlayKey = [navstar, overlay, Subnet], NewOverlayConfig, OldOverlayConfig,
             StateData = #data{config = OldConfig}) when is_tuple(Subnet), tuple_size(Subnet) == 2 ->
    DeltaOverlayConfig = determine_delta_config(NewOverlayConfig, OldOverlayConfig), 
    NewConfig = orddict:append_list(OverlayKey, DeltaOverlayConfig, OldConfig), 
    StateData#data{config = NewConfig}.

determine_delta_config(NewOverlayConfig, OldOverlayConfig) ->
    Nc = ordsets:from_list(NewOverlayConfig),
    Oc = ordsets:from_list(OldOverlayConfig),
    Dc = ordsets:subtract(Nc, Oc),
    ordsets:to_list(Dc).

maybe_update_state(StateData = #data{kill_timer = Timer, num_req = Req, num_res = Res}) when Req == Res + 1 ->
    timer:cancel(Timer),
    StateData#data{config = []}; %% clean cached config
maybe_update_state(StateData = #data{num_res = Res}) ->
    StateData#data{num_res = Res + 1}.

next_state_transition(StateData = #data{config = []}) ->
    ReapplyTimeout = application:get_env(dcos_overlay, reapply_timeout, ?REAPPLY_TIMEOUT),
    {next_state, batching, StateData, {timeout, ReapplyTimeout, do_reapply}};
next_state_transition(_StateData) ->
    keep_state_and_data.

-spec(fetch_lashup_config() -> config()).
fetch_lashup_config() ->
    MatchSpec = mk_key_matchspec(),
    OverlayKeys = lashup_kv:keys(MatchSpec),
    lists:foldl(
        fun(OverlayKey, Acc) ->
            KeyValue = lashup_kv:value(OverlayKey),
            orddict:append_list(OverlayKey, KeyValue, Acc)
        end,
        orddict:new(), OverlayKeys).

next_state_and_actions(Config, StateData0) ->
    Actions = create_actions(Config),
    {ok, Timer} = timer:kill_after(?KILL_TIMER),
    StateData1 = StateData0#data{kill_timer = Timer, num_req = length(Actions), num_res = 0},
    {StateData1, Actions}.

create_actions(Config) ->
    create_actions(Config, []).

create_actions([], Acc) ->
    lists:reverse(Acc);
create_actions([Config|Configs], Acc) ->
    Action = create_action(Config),
    create_actions(Configs, [Action|Acc]).

create_action({OverlayKey, KeyValue}) ->
    EventContent = #{key => OverlayKey, value => KeyValue},
    {next_event, internal, EventContent}.
