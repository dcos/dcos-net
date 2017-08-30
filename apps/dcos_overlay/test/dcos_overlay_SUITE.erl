%%%-------------------------------------------------------------------
%%% @author dgoel
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. Oct 2016 11:07 AM
%%%-------------------------------------------------------------------
-module(dcos_overlay_SUITE).
-author("dgoel").
%%-compile({parse_transform, lager_transform}).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2,
         init_per_suite/1,
         end_per_suite/1]).

-export([masters/0, agents/0, boot_timeout/0,
         configure_mnesia_dir/2,
         dcos_overlay_test/1]).

-export([create_data/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").

-define(AGENT_COUNT, 3).
-define(MASTER_COUNT, 1).
-define(NUM_OF_TRIES, 10).
-define(OUTPUTDIR(BaseDir), filename:join([BaseDir, "output"])).
-define(LASHUPDIR(BaseDir), filename:join([BaseDir, "lashup"])).
-define(MNESIADIR(BaseDir), filename:join([BaseDir, "mnesia"])).

init_per_suite(Config) ->
  %% this might help, might not...
  os:cmd(os:find_executable("epmd") ++ " -daemon"),
  {ok, Hostname} = inet:gethostname(),
  case net_kernel:start([list_to_atom("runner@" ++ Hostname), shortnames]) of
    {ok, _} -> ok;
    {error, {already_started, _}} -> ok
  end,
  Config.

end_per_suite(Config) ->
  net_kernel:stop(),
  Config.

all() ->
    [dcos_overlay_test].

init_per_testcase(TestCaseName, Config) ->
  ct:pal("Starting Testcase: ~p", [TestCaseName]),
  ct:timetrap(infinity),
  {Masters, Agents} = start_nodes(Config),
  {Pids, _} = rpc:multicall(Masters ++ Agents, os, getpid, []),
  Config1 = proplists:delete(pid, Config),
  [{masters, Masters}, {agents, Agents}, {pids, Pids} | Config1].

end_per_testcase(_, Config) ->
  stop_nodes(?config(agents, Config)),
  stop_nodes(?config(masters, Config)),
  cleanup_files(Config).

cleanup_files(Config) ->
  PrivateDir = ?config(priv_dir, Config),
  os:cmd("rm -rf " ++ ?LASHUPDIR(PrivateDir) ++ "/*"),
  os:cmd("rm -rf " ++ ?MNESIADIR(PrivateDir) ++ "/*").

agents() ->
  [list_to_atom(lists:flatten(io_lib:format("agent~p", [X]))) || X <- lists:seq(1, ?AGENT_COUNT)].

masters() ->
  Start = ?AGENT_COUNT + 1,
  End = ?AGENT_COUNT + ?MASTER_COUNT,
  [list_to_atom(lists:flatten(io_lib:format("master~p", [X]))) || X <- lists:seq(Start, End)].

ci() ->
  case os:getenv("CIRCLECI") of
    false ->
      false;
    _ ->
      true
  end.

%% Circle-CI can be a little slow to start agents
%% So we're bumping the boot time out to deal with that.
boot_timeout() ->
  case ci() of
    false ->
      30;
    true ->
      120
  end.

configure_output_dir(Nodes, Config) ->
   PrivateDir = ?config(priv_dir, Config),
   OutputDir = filename:join(?OUTPUTDIR(PrivateDir), node()),
   ok = filelib:ensure_dir(OutputDir ++ "/"),
   OutputEnv = [dcos_overlay, outputdir, ?OUTPUTDIR(PrivateDir)],
   {_, []} = rpc:multicall(Nodes, application, set_env, OutputEnv).

configure_lashup_dir(Nodes, Config) ->
  PrivateDir = ?config(priv_dir, Config),
  LashupDir = ?LASHUPDIR(PrivateDir),
  ok = filelib:ensure_dir(LashupDir ++ "/"),
  LashupEnv = [lashup, work_dir, LashupDir],
  {_, []} = rpc:multicall(Nodes, application, set_env, LashupEnv).

configure_mnesia_dir(Node, Config) ->
  PrivateDir = ?config(priv_dir, Config),
  MnesiaDir = filename:join(?MNESIADIR(PrivateDir), Node),
  ok = filelib:ensure_dir(MnesiaDir ++ "/"),
  MnesiaEnv = [mnesia, dir, MnesiaDir],
  ok = rpc:call(Node, application, set_env, MnesiaEnv).

start_nodes(Config) ->
  Timeout = boot_timeout(),
  Results = rpc:pmap({ct_slave, start}, [[{monitor_master, true},
    {boot_timeout, Timeout}, {init_timeout, Timeout}, {startup_timeout, Timeout},
    {erl_flags, "-connect_all false"}]], masters() ++ agents()),
  io:format("Starting nodes: ~p", [Results]),
  Nodes = [NodeName || {ok, NodeName} <- Results],
  {Masters, Agents} = lists:split(length(masters()), Nodes),
  configure_nodes(Config, Masters, Agents),
  {Masters, Agents}.

configure_nodes(Config, Masters, Agents) ->
    Nodes = Masters ++ Agents,
    Handlers = lager_config_handlers(),
    CodePath = code:get_path(),
    rpc:multicall(Nodes, code, add_pathsa, [CodePath]),
    rpc:multicall(Nodes, application, set_env, [lager, handlers, Handlers, [{persistent, true}]]),
    rpc:multicall(Nodes, application, ensure_all_started, [lager]),
    rpc:multicall(Nodes, meck, new, [httpc, [no_link, passthrough]]),
    rpc:multicall(Nodes, meck, expect, [httpc, request, fun meck_httpc_request/4]),
    configure_output_dir(Nodes, Config),
    configure_lashup_dir(Nodes, Config),
    lists:foreach(fun(Node) -> configure_mnesia_dir(Node, Config) end, Nodes),
    {_, []} = rpc:multicall(Masters, application, set_env, [lashup, contact_nodes, Masters]),
    {_, []} = rpc:multicall(Agents, application, set_env, [lashup, contact_nodes, Masters]).

lager_config_handlers() ->
    [
        {lager_console_backend, debug},
        {lager_file_backend, [
            {file, "error.log"},
            {level, error}
        ]},
        {lager_file_backend, [
            {file, "console.log"},
            {level, debug},
            {formatter, lager_default_formatter},
            {formatter_config, [
                node, ": ", time,
                " [", severity, "] ", pid,
                " (", module, ":", function, ":", line, ")",
                " ", message, "\n"
            ]}
        ]},
        {lager_common_test_backend, debug}
    ].

meck_httpc_request(get, {_, Headers}, _, _) ->
    Node = proplists:get_value("node", Headers),
    io:format(user, "Node: ~p", [Node]),
    Data = ?MODULE:create_data(list_to_binary(Node)),
    BinData = mesos_state_overlay_pb:encode_msg(Data),
    {ok, {{"HTTP/1.1", 200, "OK"}, [], BinData}}.

%% Sometimes nodes stick around on Circle-CI
%% TODO: Figure out why and troubleshoot
maybe_kill(Node) ->
  case ci() of
    true ->
      Command = io_lib:format("pkill -9 -f ~s", [Node]),
      os:cmd(Command);
    false ->
      ok
  end.

%% Borrowed from the ct_slave module
do_stop(ENode) ->
  Cover = stop_cover_enode(ENode),
  spawn(ENode, init, stop, []),
  case wait_for_node_dead(ENode, 60) of
    {ok, ENode} ->
      maybe_signal_cover_master(ENode, Cover),
      {ok, ENode};
    Error ->
      Error
  end.

stop_cover_enode(ENode) ->
  case test_server:is_cover() of
    true ->
      Main = cover:get_main_node(),
      rpc:call(Main, cover, flush, [ENode]),
      {true, Main};
    false ->
      {false, undefined}
  end.

%% To avoid that cover is started again if a node
%% with the same name is started later.
maybe_signal_cover_master(ENode, {true, MainCoverNode}) ->
  rpc:call(MainCoverNode, cover, stop, [ENode]);
maybe_signal_cover_master(_, {false, _}) ->
  ok.

% wait until timeout N seconds until node is disconnected
% relies on disterl to tell us if a node has died
% Maybe we should net_adm:ping?
wait_for_node_dead(Node, 0) ->
  {error, stop_timeout, Node};
wait_for_node_dead(Node, N) ->
  timer:sleep(1000),
  case lists:member(Node, nodes()) of
    true ->
      wait_for_node_dead(Node, N - 1);
    false ->
      {ok, Node}
  end.

stop_nodes(Nodes) ->
  StoppedResult = [do_stop(Node) || Node <- Nodes],
  ct:pal("Stopped result: ~p", [StoppedResult]),
  [maybe_kill(Node) || Node <- Nodes].


dcos_overlay_test(Config) ->
  AllNodes = ?config(agents, Config) ++ ?config(masters, Config),
  rpc:multicall(AllNodes, application, ensure_all_started, [dcos_overlay]),
  timer:sleep(60000),  %% let the system configure
  ok = check_files(?NUM_OF_TRIES, Config),
  ok = check_data(?NUM_OF_TRIES, Config).

check_files(N, Config) when N > 0 ->
  NumNodes = ?AGENT_COUNT + ?MASTER_COUNT + 1, % agents, masters and runner
  {ok, Filenames} = file:list_dir(?OUTPUTDIR(?config(priv_dir, Config))),
  io:format("Files: ~p", [Filenames]),
  case length(Filenames) of
      NumNodes ->
        ok;
      _ ->
        timer:sleep(5000), % give time for file generation
        check_files(N-1, Config)
  end;
check_files(_, _) ->
  not_ok.

check_data(N, Config) when N > 0 ->
   case verify_data(Config) of
       [] ->
         ok;
       _ ->
         timer:sleep(5000),
         check_data(N-1, Config)
     end;
check_data(_, _) ->
  not_ok.

verify_data(Config) ->
  [Master|_] = ?config(masters, Config),
  Filename = filename:join(?OUTPUTDIR(?config(priv_dir, Config)), Master),
  {ok, Actual} = file:consult(Filename),
  Expected = expected_data(Master),
  io:format("Actual ~p\n", [Actual]),
  io:format("Expected ~p\n", [Expected]),
  Result = ordsets:subtract(ordsets:from_list(Expected), ordsets:from_list(Actual)),
  io:format("Result ~p\n", [Result]),
  Result.

expected_data(Master) ->
  NumNodes = ?AGENT_COUNT + ?MASTER_COUNT,
  MasterNode = parse_node(list_to_binary(atom_to_list(Master))),
  [ get_node_data(N) || N <- lists:seq(1, NumNodes), N =/= MasterNode].

parse_node(Agent) ->
  [Bin1, _ ] = binary:split(Agent, <<"@">>),
  [_, Num] = binary:split(Bin1, [<<"master">>, <<"agent">>]),
  binary_to_integer(Num).

get_node_data(NodeNumber) ->
  AgentIP = {10, 0, 0, NodeNumber},
  Vtep_ip = {44, 128, 0, NodeNumber},
  Vtep_mac = [16#70, 16#B3, 16#D5, 16#80, 0, NodeNumber],
  Subnet = {9, 0, NodeNumber, 0},
  [AgentIP, "vtep1024", Vtep_ip, Vtep_mac, Subnet, 24].

create_data(Agent) ->
    Node = integer_to_binary(parse_node(Agent)),
    HexNode = integer_to_binary(binary_to_integer(Node, 16)),
    #mesos_state_agentinfo{
        ip = <<"10.0.0.", Node/binary>>,
        overlays = [
            #mesos_state_agentoverlayinfo{
                info = #mesos_state_overlayinfo{
                    name = <<"dcos">>,
                    prefix = 24,
                    subnet = <<"9.0.0.0/8">>
                },
                subnet = <<"9.0.", Node/binary, ".0/24">>,
                backend = #mesos_state_backendinfo{
                    vxlan = #mesos_state_vxlaninfo{
                        vni = 1024,
                        vtep_ip = <<"44.128.0.", Node/binary, "/20">>,
                        vtep_mac = <<"70:b3:d5:80:00:", HexNode/binary>>,
                        vtep_name = <<"vtep1024">>
                    }
                },
                mesos_bridge = #mesos_state_bridgeinfo{
                    name = <<"m-dcos">>,
                    ip = <<"9.0.", Node/binary, ".0/25">>
                },
                docker_bridge = #mesos_state_bridgeinfo{
                    name = <<"d-dcos">>,
                    ip = <<"9.0.", Node/binary, ".128/25">>
                },
                state = #'mesos_state_agentoverlayinfo.state'{
                    status = 'STATUS_OK'
                }
            }
        ]
    }.
