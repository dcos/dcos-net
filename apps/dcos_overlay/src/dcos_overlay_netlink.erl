%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------
-module(dcos_overlay_netlink).

%% Application callbacks
-export([replace_ipneigh/4, replace_iproute/5, replace_bridge_fdb/4,
        show_iplink/2, add_iplink/5, set_iplink/3, show_iprule/1,
        add_iprule/4, add_ipaddr/4, if_nametoindex/1]).

-include_lib("gen_netlink/include/netlink.hrl").

if_nametoindex(Ifname) ->
  gen_netlink_client:if_nametoindex(Ifname).

%% eg. replace_ipneigh(Pid, {44,128,0,1}, {16#70,16#b3,16#d5,16#80,16#00,16#03}, "vtep1024").
replace_ipneigh(Pid, Dst, Lladdr, Ifname) ->
  Attr = [{dst, Dst}, {lladdr, Lladdr}],
  Neigh = {
    _Family = inet,
    _Ifindex = if_nametoindex(Ifname),
    _State = ?NUD_PERMANENT, 
    _Flags = 0, 
    _NdmType = 0,
    Attr},
  {ok, _} = gen_netlink_client:rtnl_request(Pid, newneigh, [create, replace], Neigh).
 
%% eg. replace_iproute(Pid, {192,168,65,91}, 32, {44,128,0,1}, 42).
replace_iproute(Pid, Dst, DstPrefixLen, Src, Table) ->
  Attr = [{dst, Dst}, {gateway, Src}],
  Route = {
    _Family = inet,
    _DstPrefixLen = DstPrefixLen,
    _SrcPrefixLen = 0,
    _Tos = 0,
    _Table = Table,
    _Protocol = boot,
    _Scope = universe,
    _Type = unicast,
    _Flags = [],
    Attr},
  {ok, _} = gen_netlink_client:rtnl_request(Pid, newroute, [create, replace], Route).

%% eg. replace_bridge_fdb(Pid, {16#70,16#b3,16#d5,16#80,16#00,16#03}, {192,168,65,91}, "vtep1024").
replace_bridge_fdb(Pid, Lladdr, Dst, Ifname) ->
  Attr = [{lladdr, Lladdr},{dst, Dst}],
  Neigh = {
    _Family = bridge,
    _Ifindex = if_nametoindex(Ifname),
    _State = ?NUD_PERMANENT bor ?NUD_NOARP,
    _Flags = 16#02,  %% NTF_SELF  
    _NdmType = 0,
    Attr},
  {ok, _} = gen_netlink_client:rtnl_request(Pid, newneigh, [create, replace], Neigh).

%% eg. show_iplink(Pid, "vtep1024") -> 
%%        [{rtnetlink,newlink,[],3,31030, 
%%          {unspec,arphrd_ether,8, [lower_up,multicast,running,broadcast,up],
%%           [], [{ifname,"vtep1024"}, ...]}}]
show_iplink(Pid, Ifname) ->
  Attr = [{ifname, Ifname}, {ext_mask, 1}],
  Link = {packet, arphrd_netrom, 0, [], [], Attr},
  {ok, Resp} = gen_netlink_client:rtnl_request(Pid, getlink, [], Link), 
  Resp.

%% add_iplink(Pid, "vtep1024", "vxlan", 1024, 64000)
add_iplink(Pid, Ifname, Type, Id, DstPort) ->
  Vxlan = [{id, Id}, {ttl, 0}, {tos, 0}, {learning, 1}, {proxy, 0}, 
           {rsc, 0}, {l2miss, 0}, {l3miss, 0}, {udp_csum, 0},
           {udp_zero_csum6_tx, 0}, {udp_zero_csum6_rx, 0},
           {remcsum_tx, 0}, {remcsum_rx, 0}, {port, DstPort}],
  LinkInfo = [{kind, Type}, {data, Vxlan}],
  Attr = [{ifname, Ifname}, {linkinfo, LinkInfo}],
  Link = {
    _Family = inet,
    _Type = arphrd_netrom,
    _Ifindex = 0,
    _Flags = [],
    _Change = [],
    Attr},
  {ok, _} = gen_netlink_client:rtnl_request(Pid, newlink, [create, excl], Link).

%% set_iplink(Pid, {16#70,16#b3,16#d5,16#80,16#00,16#01}, "vtep1024").
set_iplink(Pid, Lladdr, Ifname) ->
 Attr = [{address, Lladdr}],
 Link = {
   _Family = inet,
   _Type = arphrd_netrom,
   _Ifindex = if_nametoindex(Ifname),
   _Flags = [1],
   _Change = [1],
   Attr},
 {ok, _} = gen_netlink_client:rtnl_request(Pid, newlink, [], Link).

%% show_iprule(Pid) ->
%%   [...., {rtnetlink,newrule,[multi],6,31030,
%%       {inet,0,8,0,42,unspec,universe,unicast,[],
%%          [{table,42},{priority,32765},{src,{9,0,0,0}}]}}, ....]
show_iprule(Pid) ->
 Attr = [{29, <<1:32/native-integer>>}], %% [{ext_mask, 1}] 
 Rule = {inet, 0, 0, 0, 0, 0, 0, 0, [], Attr},
 {ok, Resp} = gen_netlink_client:rtnl_request(Pid, getrule, [root, match], Rule),
 Resp.

%% add_iprule(Pid, {9,0,0,0}, 8, 42).
add_iprule(Pid, Src, SrcPrefixLen, Table) ->
 Attr = [{src, Src}],
 Rule = {
   _Family = inet,
   _DstPrefixLen = 0,
   _SrcPrefixLen = SrcPrefixLen,
   _Tos = 0,
   _Table = Table,
   _Protocol = boot,
   _Scope = universe,
   _Type = unicast,
   _Flags = [],
   Attr},
 {ok, _} = gen_netlink_client:rtnl_request(Pid, newrule, [create, excl], Rule).

%% add_ipaddr(Pid, {44,128,0,1}, 32, "vtep1024"). 
add_ipaddr(Pid, IP, PrefixLen, Ifname) ->
 Attr = [{local, IP},{address, IP}],
 Msg = {
   _Family = inet, 
   _PrefixLen = PrefixLen, 
   _Flags = 0, 
   _Scope = 0, 
   _Ifindex = if_nametoindex(Ifname), 
   Attr},
 {ok, _} = gen_netlink_client:rtnl_request(Pid, newaddr, [create, excl], Msg). 
