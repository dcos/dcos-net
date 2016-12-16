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

-export([test_iplink_add/1, test_ipneigh_replace/1, test_iproute_replace/1,
         test_bridge_fdb_replace/1, test_iplink_set/1, test_iprule_add/1,
         test_ipaddr_replace/1]).

-define(IFNAME, "vtep1024").

%% root tests
all() -> [test_iplink_add, test_ipneigh_replace, test_iproute_replace, 
          test_bridge_fdb_replace, test_iplink_set, test_iprule_add,
          test_ipaddr_replace].

init_per_testcase(TestCase, Config0) ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    Uid = list_to_integer(string:strip(os:cmd("id -u"), right, $\n)),
    io:format("UID ~p", [Uid]),
    ok = case {TestCase, Uid} of
             {test_iplink_add, _} -> iplink_del();
             {_, 0} -> iplink_add();
             {_, _} -> ok
         end,
    Config1 = proplists:delete(pid, Config0),
    [{pid, Pid} | Config1].

end_per_testcase(_, Config) ->
    iplink_del(),
    Config.

iplink_add() ->
    CMD0 = lists:flatten(io_lib:format("ip link show ~s", [?IFNAME])),
    Entry = lists:flatten(io_lib:format("~s:", [?IFNAME])),
    Data = os:cmd(CMD0),
    case string:str(Data, Entry) of
        0 -> 
          CMD1 = lists:flatten(io_lib:format("ip link add dev ~s type vxlan id 1024", [?IFNAME])),
          os:cmd(CMD1), 
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
    HexList = lists:map(fun(X) -> erlang:integer_to_list(X, 16) end, InMacList),
    lists:flatten(string:join(HexList, ":")).

test_iplink_add(Config) ->
    Pid = ?config(pid, Config),
    {ok, _} = dcos_overlay_netlink:iplink_add(Pid, ?IFNAME, "vxlan", 1024, 64000),
    CMD = lists:flatten(io_lib:format("ip link show ~s", [?IFNAME])),  
    Data = os:cmd(CMD),
    0 =/= string:str(Data, ?IFNAME).

test_ipneigh_replace(Config) ->
    Pid = ?config(pid, Config),
    DstIP = {44,128,0,1},
    DstMac = {16#70,16#b3,16#d5,16#80,16#00,16#03},
    {ok, _} = dcos_overlay_netlink:ipneigh_replace(Pid, DstIP, DstMac, ?IFNAME),
    Entry = lists:flatten(io_lib:format("~s lladdr ~s", [inet:ntoa(DstIP), mac_ntoa(DstMac)])),
    CMD = lists:flatten(io_lib:format("ip neigh show dev ~s", [?IFNAME])),
    Data = os:cmd(CMD),
    0 =/= string:str(Data, Entry).
    
test_iproute_replace(Config) ->
    Pid = ?config(pid, Config),
    DstIP = {192,168,65,91},
    SrcIP = {44,128,0,1},
    {ok, _} = dcos_overlay_netlink:iproute_replace(Pid, DstIP, 32, SrcIP, 42),
    Entry = lists:flatten(io_lib:format("~s via ~s", [inet:ntoa(DstIP), inet:ntoa(SrcIP)])),
    Data = os:cmd("ip route show table 42"),
    0 =/= string:str(Data, Entry).

test_bridge_fdb_replace(Config) ->
    Pid = ?config(pid, Config),
    DstIP = {192,168,65,91}, 
    DstMac = {16#70,16#b3,16#d5,16#80,16#00,16#03},
    {ok, _} = dcos_overlay_netlink:bridge_fdb_replace(Pid, DstIP, DstMac, ?IFNAME),
    Entry = lists:flatten(io_lib:format("~s dst ~s", [inet:ntoa(DstIP), mac_ntoa(DstMac)])),
    CMD = lists:flatten(io_lib:format("bridge fdb show dev ~s", [?IFNAME])),
    Data = os:cmd(CMD),
    0 =/= string:str(Data, Entry).
     
test_iplink_set(Config) ->
    Pid = ?config(pid, Config),
    Mac = {16#70,16#b3,16#d5,16#80,16#00,16#01},
    {ok, _} = dcos_overlay_netlink:iplink_set(Pid, Mac, ?IFNAME),
    Entry = lists:flatten(io_lib:format("link/ether ~s", [mac_ntoa(Mac)])), 
    CMD = lists:flatten(io_lib:format("ip link show ~s", [?IFNAME])),
    Data = os:cmd(CMD),
    0 =/= string:str(Data, Entry). 
    
test_iprule_add(Config) ->
    Pid = ?config(pid, Config),
    Src = {9,0,0,0}, 
    SrcPrefixLen = 8,
    {ok, _} = dcos_overlay_netlink:iprule_add(Pid, Src, SrcPrefixLen, 42),
    Entry = lists:flatten(io_lib:format("from ~s/~p lookup 42", [inet:ntoa(Src), SrcPrefixLen])),
    Data = os:cmd("ip rule show"),
    0 =/= string:str(Data, Entry).
 
test_ipaddr_replace(Config) ->
   Pid = ?config(pid, Config),
   IP = {44,128,0,1}, 
   PrefixLen = 32,
   {ok, _} = dcos_overlay_netlink:ipaddr_replace(Pid, IP, PrefixLen, ?IFNAME),
   Entry = lists:flatten(io_lib:format("inet ~s/~p scope global ~s" , [inet:ntoa(IP), PrefixLen, ?IFNAME])),
   CMD = lists:flatten(io_lib:format("ip addr show dev ~s", [?IFNAME])),
   Data = os:cmd(CMD),
   0 =/= string:str(Data, Entry). 

