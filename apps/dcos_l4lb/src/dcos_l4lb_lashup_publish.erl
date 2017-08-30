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
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {lashup_gm_monitor = erlang:error() :: reference()}).

-include("dcos_l4lb_lashup.hrl").
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
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

handle_info({'DOWN', MonitorRef, _Type, _Object, _Info}, State) when MonitorRef == State#state.lashup_gm_monitor ->
  {stop, lashup_gm_failure, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check_metadata() ->
  NodeMetadata = lashup_kv:value(?NODEMETADATA_KEY),
  NodeMetadataDict = orddict:from_list(NodeMetadata),
  Ops = check_ip(NodeMetadataDict, []),
  lager:debug("Performing ops: ~p", [Ops]),
  perform_ops(Ops).

perform_ops([]) ->
  ok;
perform_ops(Ops) ->
  {ok, _} = lashup_kv:request_op(?NODEMETADATA_KEY, {update, Ops}).

check_ip(NodeMetadata, Ops) ->
  IP = get_ip(),
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


get_ip() ->
  case get_dcos_ip() of
    false ->
      infer_ip();
    IP ->
      IP
  end.

infer_ip() ->
  ForeignIP = get_foreign_ip(),
  {ok, Socket} = gen_udp:open(0),
  inet_udp:connect(Socket, ForeignIP, 4),
  {ok, {Address, _LocalPort}} = inet:sockname(Socket),
  gen_udp:close(Socket),
  Address.

get_foreign_ip() ->
  case dcos_dns:get_leader_addr() of
    {ok, IPAddr} ->
      IPAddr;
    _ ->
      {192, 88, 99, 0}
  end.


%% Regex borrowed from:
%% http://stackoverflow.com/questions/12794358/how-to-strip-all-blank-characters-in-a-string-in-erlang
-spec(get_dcos_ip() -> false | inet:ip4_address()).
get_dcos_ip() ->
  String = os:cmd("/opt/mesosphere/bin/detect_ip"),
  String1 = re:replace(String, "(^\\s+)|(\\s+$)", "", [global, {return, list}]),
  case inet:parse_ipv4_address(String1) of
    {ok, IP} ->
      IP;
    {error, einval} ->
      false
  end.

