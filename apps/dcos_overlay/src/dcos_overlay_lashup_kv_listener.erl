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
-export([unconfigured/3, configuring/3, batching/3]).

-define(SERVER, ?MODULE).
-define(HEAPSIZE, 100). %% In MB
-define(KILL_TIMER, 300000). %% 5 min
-define(LISTEN_TIMEOUT, 5000). %% 5 secs

-include_lib("stdlib/include/ms_transform.hrl").

-type config() :: #{OverlayKey :: term() := Value :: term()}.
-type config2() :: #{key := term(), value := term()}.

-record(data, {
    ref :: reference(),
    pid :: undefined | pid(),
    config = maps:new() :: config(),
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
    {ok, Ref} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({[navstar, overlay, '_']}) -> true end)),
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

%%--------------------------------------------------------------------------------
%% State transition
%%-------------------------------------------------------------------------------- 
%%                                                                lashup_event
%%                                                                  +------+
%%                                                                  |      |
%%  +--------------+              +----------------+              +-+--------+
%%  |              |              |                |              |          |
%%  |              | lashup_event |                | lashup event |          |
%%  | unconfigured +------------> |  configuring   +------------> | batching |
%%  |              |              |                |              |          |
%%  |              |              |                | <------------|          |
%%  |              |              |                |   timeout    |          |
%%  +--------------+              +----------------+              +----------+
%%
%%--------------------------------------------------------------------------------

unconfigured(info, EventContent, Data) ->
    {next_state, configuring, Data, {next_event, internal, EventContent}}.

configuring(internal, {lashup_kv_events, #{key := [navstar, overlay, Subnet] = OverlayKey, value := Value, ref := Ref}},
            Data0 = #data{ref = Ref, config = OldConfig}) when is_tuple(Subnet), tuple_size(Subnet) == 2 ->
    NewConfig = #{key => OverlayKey, value => Value},
    DeltaConfig = delta_config(NewConfig, OldConfig),
    lager:debug("Applying configuration: ~p", [DeltaConfig]),
    {ok, Timer} = timer:kill_after(?KILL_TIMER),
    dcos_overlay_configure:start_link(DeltaConfig),
    Data1 = Data0#data{kill_timer = Timer},
    {keep_state, Data1};
configuring(info, {dcos_overlay_configure, applied_config, DeltaConfig},
            Data0 = #data{kill_timer = Timer, config = OldConfig}) ->
    timer:cancel(Timer),
    lager:debug("Done applying configuration: ~p", [DeltaConfig]),
    NewConfig = update_config(DeltaConfig, OldConfig),
    Data1 = Data0#data{config = NewConfig},
    {next_state, batching, Data1};
configuring(info, _EventContent, _Data) ->
    {keep_state_and_data, postpone}.
            
batching(info, EventContent, _Data) ->
    {keep_state_and_data, {timeout, ?LISTEN_TIMEOUT, {do_configure, EventContent}}};
batching(timeout, {do_configure, EventContent}, Data) ->
    {next_state, configuring, Data, {next_event, internal, EventContent}}.

%% private API

-spec(delta_config(NewConfig :: config2(), OldConfig :: config()) -> config2()).
delta_config(NewConfig = #{key := OverlayKey, value := NewValue}, OldConfig) ->
    case maps:get(OverlayKey, OldConfig, []) of
        [] ->
            NewConfig;
        OldValue ->
            DeltaValue = ordsets:to_list(ordsets:subtract(ordsets:from_list(NewValue), OldValue)),
            #{key => OverlayKey, value => DeltaValue}
    end.

-spec(update_config(config2(), OldConfig :: config()) -> config()).
update_config(#{key := OverlayKey, value := DeltaValue}, OldConfig) ->
    NewValue = case maps:get(OverlayKey, OldConfig, []) of
                   [] ->
                      ordsets:from_list(DeltaValue);
                   OldValue ->
                      ordsets:union(ordsets:from_list(DeltaValue), OldValue)
               end,
    maps:put(OverlayKey, NewValue, OldConfig).
