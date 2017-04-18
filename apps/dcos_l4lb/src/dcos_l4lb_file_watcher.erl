%%%-------------------------------------------------------------------
%%% @author dgoel
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. April 2017 2:35 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_file_watcher).
-author("dgoel").

-behaviour(gen_server).

-include_lib("inotify/include/inotify.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

%% inotify_evt callbacks
-export([inotify_event/3]).

-define(SERVER, ?MODULE).

-record(state, {watchRef :: undefined | reference()}).
-type state() :: #state{}.
-type mask() :: ?ALL.
-type msg() :: ?inotify_msg(Mask :: [mask()],
                            Cookie :: non_neg_integer(),
                            OptionalName :: string()).

-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  Dir = application:get_env(dcos_l4lb, cni_dir, []),
  gen_server:start_link({local, ?SERVER}, ?MODULE, [Dir], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([[]]) ->
  {ok, #state{}};
init([Dir]) ->
  Ref = inotify:watch(Dir, ?CLOSE_WRITE),
  ok = inotify:add_handler(Ref, ?MODULE, self()),
  {ok, #state{watchRef = Ref}}. 

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
  State :: state()) ->
  {reply, Reply :: term(), NewState :: state()} |
  {reply, Reply :: term(), NewState :: state(), timeout() | hibernate} |
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: state()} |
  {stop, Reason :: term(), NewState :: state()}).
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: state()) ->
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: state()}).
handle_cast({[?CLOSE_WRITE], _FileName, Ref}, State = #state{watchRef = Ref}) ->  
  {noreply, State}; 
handle_cast(_Request, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: state()) ->
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: state()}).
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
  State :: state()) -> term()).
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: state(),
  Extra :: term()) ->
  {ok, NewState :: state()} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% inotify callback
%%%===================================================================
-spec(inotify_event(Arg :: term(), EventRef :: reference, Event :: msg()) -> ok).
inotify_event(_Pid, _Ref, ?inotify_msg(_Masks, _Cookie, [$.|_])) ->
    ok;
inotify_event(Pid, Ref, ?inotify_msg(Masks, _Cookie, FileName)) ->
    gen_server:cast(Pid, {Masks, FileName, Ref}).
