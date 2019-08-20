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

-include_lib("kernel/include/logger.hrl").
-include_lib("inotify/include/inotify.hrl").
-include("dcos_l4lb.hrl").

%% API
-export([start_link/0]).

%% gen_statem callbacks
-export([init/1, callback_mode/0]).

%% State callbacks
-export([uninitialized/3, reconcile/3, watch/3]).

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

init([]) ->
  CniDir = dcos_l4lb_config:cni_dir(),
  StateData = #data{cni_dir = CniDir},
  {ok, uninitialized, StateData, {next_event, timeout, CniDir}}.

callback_mode() ->
    state_functions.

%%--------------------------------------------------------------------
%% State transition uninitialized -> reconcile -> maintain
%%--------------------------------------------------------------------

uninitialized(timeout, CniDir, StateData0 = #data{cni_dir = CniDir}) ->
  case filelib:is_dir(CniDir) of
      true ->
          Ref = setup_watch(CniDir),
          StateData1 = StateData0#data{watchRef = Ref},
          {next_state, reconcile, StateData1, {next_event, internal, CniDir}};
      false ->
          {keep_state_and_data, {timeout, 5000, CniDir}}
   end.

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
  ?LOG_WARNING("Unknown event ~p with ~p", [EventType, EventContent]),
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
    Ref = inotify:watch(CniDir, [?CLOSE_WRITE, ?DELETE]),
    ok = inotify:add_handler(Ref, ?MODULE, self()),
    Ref.

send_event(_, []) ->
  ok;
send_event(EventType, EventContent) ->
  dcos_l4lb_mgr:push_netns(EventType, EventContent).

read_files(CniDir) ->
  case file:list_dir(CniDir) of
      {ok, FileNames} ->
          lists:filtermap(fun(FileName) -> read_file(FileName, CniDir) end, FileNames);
      {error, Reason} ->
          ?LOG_INFO("Couldn't read cni dir ~p due to ~p", [CniDir, Reason]),
          []
  end.

read_file(FileName, CniDir) ->
    AbsFileName = filename:join(CniDir, FileName),
    case file:read_file(AbsFileName) of
        {ok, Namespace} ->
            {true, #netns{id = FileName, ns = Namespace}};
        {error, Reason} ->
            ?LOG_WARNING("Couldn't read ~p, due to ~p", [AbsFileName, Reason]),
            false
    end.
