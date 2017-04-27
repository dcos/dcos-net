%%%-------------------------------------------------------------------
%%% @author dgoel
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. April 2017 2:35 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_netns_watcher).
-author("dgoel").

-behaviour(gen_statem).

-include_lib("inotify/include/inotify.hrl").
-include("dcos_l4lb.hrl").

%% API
-export([start_link/0]).

%% gen_statem callbacks
-export([init/1, terminate/3, code_change/4, callback_mode/0]).

%% State callbacks
-export([reconcile/3, watch/3]).

%% inotify_evt callbacks
-export([inotify_event/3]).

-define(SERVER, ?MODULE).
-define(RECONCILE_TIMEOUT, 5000). %% 5 secs

-record(data, {cni_dir :: undefined | string(),
               watchRef :: undefined | reference()}).

-type mask() :: ?ALL.
-type msg() :: ?inotify_msg(Mask :: [mask()],
                            Cookie :: non_neg_integer(),
                            OptionalName :: string()).

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
init([]) ->
  CniDir = dcos_l4lb_config:cni_dir(),
  Ref = setup_watch(CniDir),
  StateData = #data{cni_dir = CniDir, watchRef = Ref},
  {ok, reconcile, StateData, {next_event, internal, CniDir}}.

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
terminate(Reason, State, Data) ->
    lager:warning("Terminating, due to: ~p, in state: ~p, with state data: ~p", [Reason, State, Data]).

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

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec callback_mode() -> handle_event_function | state_functions
%% @end
%% --------------------------------------------------------------------
-spec(callback_mode() -> handle_event_function | state_functions).
callback_mode() ->
    state_functions.

%%--------------------------------------------------------------------
%% State transition reconcile -> maintain
%%--------------------------------------------------------------------
reconcile(internal, CniDir, StateData = #data{cni_dir = CniDir}) ->
  Namespaces = read_files(CniDir),
  send_event(reconcile_netns, Namespaces),
  {next_state, watch, StateData};
reconcile(_, _, _) ->
  {keep_state_and_data, postpone}.  

watch(cast, {[?CLOSE_WRITE], FileName, Ref}, #data{cni_dir = CniDir, watchRef = Ref}) ->  
  {true, Netns} = read_file(FileName, CniDir),
  send_event(add_netns, [Netns]),
  keep_state_and_data; 
watch(cast, {[?DELETE], FileName, Ref}, #data{watchRef = Ref}) ->
  send_event(remove_netns, [#netns{id = FileName}]),
  keep_state_and_data;
watch(EventType, EventContent, _) ->
  lager:warning("Unknown event ~p with ~p", [EventType, EventContent]),
  keep_state_and_data.

%%%===================================================================
%%% inotify callback
%%%===================================================================
-spec(inotify_event(Arg :: term(), EventRef :: reference, Event :: msg()) -> ok).
inotify_event(_Pid, _Ref, ?inotify_msg(_Masks, _Cookie, [$.|_])) ->
    ok;
inotify_event(Pid, Ref, ?inotify_msg(Masks, _Cookie, FileName)) ->
    gen_statem:cast(Pid, {Masks, FileName, Ref}).

%%%====================================================================
%%% private api
%%%====================================================================
setup_watch(CniDir) ->
    case filelib:is_dir(CniDir) of
        true -> 
            Ref = inotify:watch(CniDir, [?CLOSE_WRITE,?DELETE]),
            ok = inotify:add_handler(Ref, ?MODULE, self()),
            Ref;
        false ->
            undefined
    end.

send_event(_, []) ->
  ok;
send_event(EventType, EventContent) ->
  dcos_l4lb_mgr:push_netns(EventType, EventContent).

read_files(CniDir) ->
  case file:list_dir(CniDir) of
      {ok, FileNames} ->
          lists:filtermap(fun(FileName) -> read_file(FileName, CniDir) end, FileNames);
      {error, Reason} ->
          lager:info("Couldn't read cni dir ~p due to ~p", [CniDir, Reason]),
          []
  end.
    
read_file(FileName, CniDir) ->
    AbsFileName = filename:join(CniDir, FileName),
    case file:read_file(AbsFileName) of
        {ok, Binary} -> 
            {true, #netns{id = FileName, file = Binary}};
        {error, Reason} -> 
            lager:warning("Couldn't read ~p, due to ~p", [AbsFileName, Reason]),
            false
    end.
