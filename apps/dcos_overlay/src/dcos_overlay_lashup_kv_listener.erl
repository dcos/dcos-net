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
-define(LISTEN_TIMEOUT, 1000). %% 1 secs

-include_lib("stdlib/include/ms_transform.hrl").

-record(data, {
    ref :: reference(),
    pid :: undefined | pid(),
    events = maps:new() :: map()
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
    MaxHeapSizeInWords = (100 bsl 20) div erlang:system_info(wordsize), %%100 MB
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

configuring(internal, {lashup_kv_events, NewEvent = #{key := [navstar, overlay, Subnet], ref := Ref}},
            #data{ref = Ref, events = OldEvent}) when is_tuple(Subnet), tuple_size(Subnet) == 2 ->
    DeltaEvent = get_delta_event(NewEvent, OldEvent),
    lager:debug("Applying configuration: ~p", [DeltaEvent]),
    dcos_overlay_configure:start_link(reply, DeltaEvent),
    keep_state_and_data;
configuring(info, {dcos_overlay_configure, applied_config, DeltaEvent}, Data0) ->
    lager:debug("Done applying configuration: ~p", [DeltaEvent]),
    Data1 = update_state_data(DeltaEvent, Data0),
    {next_state, batching, Data1};
configuring(info, _EventContent, _Data) ->
    {keep_state_and_data, postpone}.
            
batching(info, EventContent, _Data) ->
    {keep_state_and_data, {timeout, ?LISTEN_TIMEOUT, {do_configure, EventContent}}};
batching(timeout, {do_configure, EventContent}, Data) ->
    {next_state, configuring, Data, {next_event, internal, EventContent}}.

%% private API

-spec(get_delta_event(lashup_kv:kv2(), #{[any()] := map()}) -> lashup_kv:kv2()).
get_delta_event(NewEvent = #{key := Key, value := NewValue}, OldEvent) ->
    case maps:get(Key, OldEvent, []) of
      [] -> 
          NewEvent;
      OldValue ->
          DeltaValue = ordsets:to_list(ordsets:subtract(ordsets:from_list(NewValue), OldValue)),
          maps:put(value, DeltaValue, NewEvent)
    end.

-spec(update_state_data(lashup:kv2(), #data{}) -> #data{}).
update_state_data(#{key := Key, value := DeltaValue}, Data = #data{events = Event0}) ->
    Event1 = case maps:get(Key, Event0, []) of
               [] ->
                   maps:put(Key, DeltaValue, Event0);
               OldValue ->
                   NewValue = ordsets:union(ordsets:from_list(DeltaValue), OldValue),
                   maps:put(Key, NewValue, Event0)
             end,
    Data#data{events = Event1}.
