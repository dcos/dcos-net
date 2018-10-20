-module(dcos_overlay_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2,
         init_per_suite/1,
         end_per_suite/1]).

-export([dcos_overlay_test/1]).

-export([create_data/1]).

all() ->
    [dcos_overlay_test].

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("gen_netlink/include/netlink.hrl").

-define(MASTERS, [master1]).
-define(AGENTS, [agent2, agent3, agent4]).

init_per_suite(Config) ->
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

init_per_testcase(TestCaseName, Config) ->
    ct:pal("Starting Testcase: ~p", [TestCaseName]),
    Nodes = start_nodes(?MASTERS ++ ?AGENTS),
    configure_nodes(Nodes, masters(Nodes)),
    [{nodes, Nodes} | Config].

end_per_testcase(_, Config) ->
    stop_nodes(?config(nodes, Config)),
    Config.

masters(Nodes) ->
    element(1, lists:split(length(?MASTERS), Nodes)).

start_nodes(Nodes) ->
    Opts = [{monitor_master, true}, {erl_flags, "-connect_all false"}],
    Result = [ct_slave:start(Node, Opts) || Node <- Nodes],
    ct:pal("Started result ~p", [Result]),
    NodeNames = [NodeName || {ok, NodeName} <- Result],
    lists:foreach(fun(Node) -> pong = net_adm:ping(Node) end, NodeNames),
    NodeNames.

configure_nodes(Nodes, Masters) ->
    Env = [lashup, contact_nodes, Masters],
    {_, []} = rpc:multicall(Nodes, code, add_pathsa, [code:get_path()]),
    {_, []} = rpc:multicall(Nodes, application, set_env, Env),
    {_, []} = rpc:multicall(Nodes, meck, new, [httpc, [no_link, passthrough]]),
    {_, []} = rpc:multicall(Nodes, meck, expect, [httpc, request, fun meck_httpc_request/4]).

stop_nodes(Nodes) ->
    StoppedResult = [ct_slave:stop(Node) || Node <- Nodes],
    lists:foreach(fun(Node) -> pang = net_adm:ping(Node) end, Nodes),
    ct:pal("Stopped result: ~p", [StoppedResult]).

meck_httpc_request(get, {_, Headers}, _, [{sync, false}]) ->
    UserAgent = proplists:get_value("User-Agent", Headers),
    [Node, _] = string:split(UserAgent, " "),
    io:format(user, "Node: ~p", [Node]),
    Data = ?MODULE:create_data(list_to_binary(Node)),
    BinData = jiffy:encode(Data),
    Ref = make_ref(),
    Response = {{"HTTP/1.1", 200, "OK"}, [], BinData},
    self() ! {http, {Ref, Response}},
    {ok, Ref}.

dcos_overlay_test(Config) ->
    Nodes = ?config(nodes, Config),
    meck_setup(Nodes),
    Expected = expected(Nodes),
    Actual = actual(Nodes),
    ?assertMatch(Expected, Actual).

meck_setup(Nodes) ->
    {_, []} = rpc:multicall(Nodes, erlang, apply, [fun() ->
        meck:new(dcos_overlay_configure, [no_link, passthrough]),
        meck:expect(dcos_overlay_configure, configure_overlay, fun (_, _) -> ok end),

        meck:new(gen_netlink_client, [no_link, passthrough]),
        meck:expect(gen_netlink_client, rtnl_request,
            fun (_, Type, _, _) when Type == getlink ->
                    Msg = {unspec, arphrd_ether, 13, [], [], []},
                    {ok, [#rtnetlink{type=newlink, msg=Msg}]};
                (_, _, _, _) -> {ok, []}
            end),
        meck:expect(gen_netlink_client, if_nametoindex, fun (_) -> {ok, 0} end),
        application:ensure_all_started(dcos_overlay)
    end, []]).

actual(Nodes) ->
    {Result, []} = rpc:multicall(Nodes, meck, wait,
                       [3, dcos_overlay_configure, configure_overlay, ['_', '_'], 120000]),
    ct:pal("wait result ~p", [Result]),
    {First, []} = rpc:multicall(Nodes, meck, capture,
                      [first, dcos_overlay_configure, configure_overlay, ['_', '_'], 2]),
    {Second, []} = rpc:multicall(Nodes, meck, capture,
                       [2, dcos_overlay_configure, configure_overlay, ['_', '_'], 2]),
    {Third, []} = rpc:multicall(Nodes, meck, capture,
                       [3, dcos_overlay_configure, configure_overlay, ['_', '_'], 2]),
    Zipped = lists:zipwith3(fun(X, Y, Z) -> [X, Y, Z] end, First, Second, Third),
    [lists:sort(L) || L <- Zipped].

expected(Nodes) ->
    NodeNums = [parse_node(atom_to_binary(Node, latin1)) || Node <- Nodes],
    [lists:sort(
        [node_config(Node) || Node <- NodeNums, Node =/= NodeNum])
     || NodeNum <- NodeNums].

node_config(Node) ->
    AgentIP = {10, 0, 0, Node},
    Vtep_ip = {44, 128, 0, Node},
    Vtep_mac = [16#70, 16#B3, 16#D5, 16#80, 0, Node],
    Subnet = {9, 0, Node, 0},
    [AgentIP, "vtep1024", Vtep_ip, Vtep_mac, Subnet, 24].

parse_node(Agent) ->
  [Bin1, _ ] = binary:split(Agent, <<"@">>),
  [_, Num] = binary:split(Bin1, [<<"master">>, <<"agent">>]),
  binary_to_integer(Num).

create_data(Agent) ->
    Node = integer_to_binary(parse_node(Agent)),
    HexNode = integer_to_binary(binary_to_integer(Node, 16)),
    #{
        ip => <<"10.0.0.", Node/binary>>,
        overlays => [
            #{
                info => #{
                    name => <<"dcos">>,
                    prefix => 24,
                    subnet => <<"9.0.0.0/8">>
                },
                subnet => <<"9.0.", Node/binary, ".0/24">>,
                backend => #{
                    vxlan => #{
                        vni => 1024,
                        vtep_ip => <<"44.128.0.", Node/binary, "/20">>,
                        vtep_mac => <<"70:b3:d5:80:00:", HexNode/binary>>,
                        vtep_name => <<"vtep1024">>
                    }
                },
                mesos_bridge => #{
                    name => <<"m-dcos">>,
                    ip => <<"9.0.", Node/binary, ".0/25">>
                },
                docker_bridge => #{
                    name => <<"d-dcos">>,
                    ip => <<"9.0.", Node/binary, ".128/25">>
                },
                state => #{
                    status => <<"STATUS_OK">>
                }
            }
        ]
    }.
