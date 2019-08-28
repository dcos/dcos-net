%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 12. Feb 2016 3:14 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_lashup_publish).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3,
  handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-record(state, {lashup_gm_monitor = erlang:error() :: reference()}).

-include("dcos_l4lb_lashup.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/inet.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
  Ref = monitor(process, lashup_gm),
  State = #state{lashup_gm_monitor = Ref},
  gen_server:cast(self(), check_metadata),
  {ok, State}.

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast(check_metadata, State) ->
  check_metadata(),
  {noreply, State, hibernate};
handle_cast(_Request, State) ->
  {noreply, State}.

handle_info({'DOWN', MonitorRef, _Type, _Object, _Info}, State) when MonitorRef == State#state.lashup_gm_monitor ->
  {stop, lashup_gm_failure, State};
handle_info(_Info, State) ->
  {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check_metadata() ->
  NodeMetadata = lashup_kv:value(?NODEMETADATA_KEY),
  NodeMetadataDict = orddict:from_list(NodeMetadata),
  Ops = check_ip(NodeMetadataDict, []),
  ?LOG_DEBUG("Performing ops: ~p", [Ops]),
  perform_ops(Ops).

perform_ops([]) ->
  ok;
perform_ops(Ops) ->
  {ok, _} = lashup_kv:request_op(?NODEMETADATA_KEY, {update, Ops}).

check_ip(NodeMetadata, Ops) ->
  IP = dcos_net_dist:nodeip(),
  check_ip(IP, NodeMetadata, Ops).

check_ip(IP, NodeMetadata, Ops) ->
  Node = node(),
  case orddict:find(?LWW_REG(IP), NodeMetadata) of
    {ok, Node} ->
      Ops;
    _ ->
      set_ip(IP, Node, Ops)
  end.

set_ip(IP, Node, Ops) ->
  [{update, ?LWW_REG(IP), {assign, Node, erlang:system_time(nano_seconds)}}|Ops].
