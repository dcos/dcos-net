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
-export([unconfigured/3, applying_first_config/3, batching/3, configuring/3]).

-define(SERVER, ?MODULE).
-define(LISTEN_TIMEOUT, 10000). %% 10 secs
-define(NOW, 0).

-include_lib("stdlib/include/ms_transform.hrl").

-record(data, {
    ref :: reference(),
    pid :: undefined | pid()
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

%%-------------------------------------------------------------------------------------------------------------
%% State transition
%% 
%%                                                                lashup_event
%%                                                                  +------+
%%                                                                  |      |
%%  +--------------+              +----------------+              +-+--------+                +-------------+
%%  |              |              |                |              |          |                |             |
%%  |              | lashup_event |                | lashup event |          |   timeout      |             |
%%  | unconfigured +------------> |    applying    +------------> | batching +--------------> | configuring |
%%  |              |              |  first_config  |              |          |                |             |
%%  |              |              |                |              |          | <--------------+             |
%%  |              |              |                |              |          |  lashup_event  |             |
%%  +--------------+              +----------------+              +----------+                +-------------+
%%
%%--------------------------------------------------------------------------------------------------------------

unconfigured(info, EventContent, Data) ->
    {next_state, applying_first_config, Data, {next_event, internal, EventContent}}.

applying_first_config(internal, 
            _EventContent = {lashup_kv_events, Event = #{key := [navstar, overlay, Subnet], ref := Ref}},
            _Data = #data{ref = Ref}) when is_tuple(Subnet), tuple_size(Subnet) == 2 ->
    lager:info("Applying first config: ~p~n", [Event]),
    dcos_overlay_configure:start_link(reply, Event),
    keep_state_and_data;
applying_first_config(info, {dcos_overlay_configure, applied_config}, Data) ->
    lager:info("Done applying first config"),
    {next_state, batching, Data};
applying_first_config(info, _EventContent, _Data) ->
    {keep_state_and_data, postpone}.
            
batching(info, EventContent, _Data) ->
    {keep_state_and_data, {timeout, ?LISTEN_TIMEOUT, {do_configure, EventContent}}};
batching(timeout, {do_configure, EventContent}, Data) ->
    {next_state, configuring, Data, {next_event, internal, EventContent}}.

configuring(internal, {lashup_kv_events, Event = #{key := [navstar, overlay, Subnet], ref := Ref}},
            Data0 = #data{ref = Ref}) when is_tuple(Subnet), tuple_size(Subnet) == 2 ->
    Pid = dcos_overlay_configure:start_link(noreply, Event),
    lager:debug("Starting configurator ~p for config: ~p~n", [Pid, Event]), 
    Data1 = Data0#data{pid = Pid},
    {keep_state, Data1};
configuring(info, _EventContent, Data) ->
    %% Short circuit the current configurator
    %% as there is an updated configuration
    lager:debug("Killing configurator ~p as new config received", [Data#data.pid]), 
    dcos_overlay_configure:stop(Data#data.pid),
    {next_state, batching, Data, postpone}.
