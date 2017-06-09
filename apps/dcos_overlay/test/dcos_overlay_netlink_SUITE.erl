%%%-------------------------------------------------------------------
%%% @author dgoel
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 07. Dec 2016 7:17 PM
%%%-------------------------------------------------------------------
-module(dcos_overlay_netlink_SUITE).
-author("dgoel").

-include_lib("gen_netlink/include/netlink.hrl").
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-export([
    test_ip_cmds_1/1,
    test_ip_cmds_2/1,
    test_ip_cmds_3/1,
    test_ip_cmds_4/1,
    test_ip_cmds_5/1,
    test_bridge_fdb_replace/1,
    test_iprule_cmds/1
]).

-define(IFNAME, "vtep1025").

%% root tests
all() -> [
    test_ip_cmds_1,
    test_ip_cmds_2,
    test_ip_cmds_3,
    test_ip_cmds_4,
    test_ip_cmds_5,
    test_bridge_fdb_replace,
    test_iprule_cmds
].

init_per_testcase(TestCase, Config) ->
    Uid = list_to_integer(string:strip(os:cmd("id -u"), right, $\n)),
    init_per_testcase(Uid, TestCase, Config).

init_per_testcase(0, TestCase, Config0) ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    case TestCase of
        test_ip_cmds_1 -> iplink_del();
        _ -> iplink_add()
    end,
    Config1 = proplists:delete(pid, Config0),
    [{pid, Pid} | Config1];
init_per_testcase(_, _, _) ->
    {skip, "Not running as root"}.

end_per_testcase(_, Config) ->
    iplink_del(),
    Config.

iplink_add() ->
    CMD0 = lists:flatten(io_lib:format("ip link show ~s", [?IFNAME])),
    Entry = lists:flatten(io_lib:format("~s:", [?IFNAME])),
    Data = os:cmd(CMD0),
    case string:str(Data, Entry) of
        0 ->
          os:cmd(lists:flatten(io_lib:format("ip link add dev ~s type vxlan id 1024", [?IFNAME]))),
          os:cmd(lists:flatten(io_lib:format("ip link set ~s up", [?IFNAME]))),
          ok;
        _ ->
          ok
    end.

iplink_del() ->
    CMD = lists:flatten(io_lib:format("ip link del ~s", [?IFNAME])),
    os:cmd(CMD),
    ok.

mac_ntoa(InMac) ->
    InMacList = tuple_to_list(InMac),
    lists:flatten(io_lib:format("~2.16.0b:~2.16.0b:~2.16.0b:~2.16.0b:~2.16.0b:~2.16.0b", InMacList)).

%% these commands depends on each other so better to test them together
test_ip_cmds_1(Config) ->
    %% Test1: add ip link
    Pid = ?config(pid, Config),
    {ok, _} = dcos_overlay_netlink:iplink_add(Pid, ?IFNAME, "vxlan", 1026, 64000),
    Result1 = os:cmd(lists:flatten(io_lib:format("ip link show ~s", [?IFNAME]))),
    io:format("Result1 ~p~n", [Result1]),
    true = 0 =/= string:str(Result1, ?IFNAME).

test_ip_cmds_2(Config) ->
    %% Test2: set ip link
    Pid = ?config(pid, Config),
    Mac = {16#70, 16#b3, 16#d5, 16#80, 16#00, 16#01},
    MacStr = mac_ntoa(Mac),
    {ok, _} = dcos_overlay_netlink:iplink_set(Pid, Mac, ?IFNAME),
    Entry2 = lists:flatten(io_lib:format("link/ether ~s", [MacStr])),
    Result2 = os:cmd(lists:flatten(io_lib:format("ip link show ~s", [?IFNAME]))),
    io:format("Result2 ~p, Entry2 ~p~n", [Result2, Entry2]),
    true = 0 =/= string:str(Result2, Entry2).

test_ip_cmds_3(Config) ->
    %% Test3: ip addr replace
    Pid = ?config(pid, Config),
    IP = {44, 128, 0, 1},
    IPStr = inet:ntoa(IP),
    PrefixLen = 32,
    {ok, _} = dcos_overlay_netlink:ipaddr_replace(Pid, IP, PrefixLen, ?IFNAME),
    Entry3 = lists:flatten(io_lib:format("inet ~s/~p scope global ~s" , [IPStr, PrefixLen, ?IFNAME])),
    Result3 = os:cmd(lists:flatten(io_lib:format("ip addr show dev ~s", [?IFNAME]))),
    io:format("Result3 ~p, Entry3 ~p~n", [Result3, Entry3]),
    true = 0 =/= string:str(Result3, Entry3).

test_ip_cmds_4(Config) ->
    %% Test4: ipneigh replace
    Pid = ?config(pid, Config),
    Mac = {16#70, 16#b3, 16#d5, 16#80, 16#00, 16#01},
    IP = {44, 128, 0, 1},
    IPStr = inet:ntoa(IP),
    MacStr = mac_ntoa(Mac),
    {ok, _} = dcos_overlay_netlink:ipneigh_replace(Pid, IP, Mac, ?IFNAME),
    Entry4 = lists:flatten(io_lib:format("~s lladdr ~s", [IPStr, MacStr])),
    Result4 = os:cmd(lists:flatten(io_lib:format("ip neigh show dev ~s", [?IFNAME]))),
    io:format("Result4 ~p, Entry4 ~p~n", [Result4, Entry4]),
    true = 0 =/= string:str(Result4, Entry4).

test_ip_cmds_5(Config) ->
    %% Test5: ip route replace
    Pid = ?config(pid, Config),
    IP = {44, 128, 0, 1},
    IPStr = inet:ntoa(IP),
    DstIP = {192, 168, 65, 91},
    {ok, _} = dcos_overlay_netlink:iproute_replace(Pid, DstIP, 32, IP, 42),
    Entry5 = lists:flatten(io_lib:format("~s via ~s", [inet:ntoa(DstIP), IPStr])),
    Result5 = os:cmd("ip route show table 42"),
    io:format("Result5 ~p, Entry5 ~p~n", [Result5, Entry5]),
    true = 0 =/= string:str(Result5, Entry5).

test_bridge_fdb_replace(Config) ->
    Pid = ?config(pid, Config),
    DstIP = {192, 168, 65, 91},
    DstMac = {16#70, 16#b3, 16#d5, 16#80, 16#00, 16#03},
    {ok, _} = dcos_overlay_netlink:bridge_fdb_replace(Pid, DstIP, DstMac, ?IFNAME),
    Entry = lists:flatten(io_lib:format("~s dst ~s", [mac_ntoa(DstMac), inet:ntoa(DstIP)])),
    Result = os:cmd(lists:flatten(io_lib:format("bridge fdb show dev ~s", [?IFNAME]))),
    io:format("Result ~p, Entry ~p~n", [Result, Entry]),
    true = 0 =/= string:str(Result, Entry).

test_iprule_cmds(Config) ->
    Pid = ?config(pid, Config),

    %% Test1: ip rule add
    Src = {9, 0, 0, 0},
    SrcPrefixLen = 8,
    {ok, _} = dcos_overlay_netlink:iprule_add(Pid, Src, SrcPrefixLen, 42),
    Entry = lists:flatten(io_lib:format("from ~s/~p lookup 42", [inet:ntoa(Src), SrcPrefixLen])),
    Result = os:cmd("ip rule show"),
    io:format("Result ~p Entry ~p~n", [Result, Entry]),
    true = 0 =/= string:str(Result, Entry),

    %% Test2: ip rule show
    {ok, Rules} = dcos_overlay_netlink:iprule_show(Pid),
    Rule = dcos_overlay_netlink:make_iprule(Src, SrcPrefixLen, 42),
    true = dcos_overlay_netlink:is_iprule_present(Rules, Rule).
