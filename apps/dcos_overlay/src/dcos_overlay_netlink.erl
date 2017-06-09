%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------
-module(dcos_overlay_netlink).

%% Application callbacks
-export([start_link/0, stop/1, ipneigh_replace/4, iproute_replace/5, bridge_fdb_replace/4,
        iplink_show/2, iplink_add/5, iplink_set/3, iprule_show/1,
        iprule_add/4, make_iprule/3, match_iprules/2, is_iprule_present/2,
        ipaddr_replace/4, if_nametoindex/1]).

-include_lib("gen_netlink/include/netlink.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(TEST_OR_DEV, true).
-endif.

-ifdef(DEV).
-define(TEST_OR_DEV, true).
-endif.

start_link() ->
   gen_netlink_client:start_link(?NETLINK_ROUTE).

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

%% eg. ipneigh_replace(Pid, {44,128,0,1}, {16#70,16#b3,16#d5,16#80,16#00,16#03}, "vtep1024").
ipneigh_replace(Pid, Dst, Lladdr, Ifname) ->
  Attr = [{dst, Dst}, {lladdr, Lladdr}],
  Ifindex = if_nametoindex(Ifname),
  Neigh = {
    _Family = inet,
    _Ifindex = Ifindex,
    _State = ?NUD_PERMANENT, 
    _Flags = 0, 
    _NdmType = 0,
    Attr},
  netlink_request(Pid, newneigh, [create, replace], Neigh).

%% eg. iproute_replace(Pid, {192,168,65,91}, 32, {44,128,0,1}, 42).
iproute_replace(Pid, Dst, DstPrefixLen, Src, Table) ->
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
  netlink_request(Pid, newroute, [create, replace], Route).

%% eg. bridge_fdb_replace(Pid, {192,168,65,91}, {16#70,16#b3,16#d5,16#80,16#00,16#03}, "vtep1024").
bridge_fdb_replace(Pid, Dst, Lladdr, Ifname) ->
  Attr = [{dst, Dst}, {lladdr, Lladdr}],
  State = ?NUD_PERMANENT bor ?NUD_NOARP,
  Ifindex = if_nametoindex(Ifname),
  Neigh = {
    _Family = bridge,
    _Ifindex = Ifindex,
    _State = State,
    _Flags = 2,  %% NTF_SELF  
    _NdmType = 0,
    Attr},
  netlink_request(Pid, newneigh, [create, replace], Neigh).

%% eg. iplink_show(Pid, "vtep1024") -> 
%%        [{rtnetlink,newlink,[],3,31030, 
%%          {unspec,arphrd_ether,8, [lower_up,multicast,running,broadcast,up],
%%           [], [{ifname,"vtep1024"}, ...]}}]
iplink_show(Pid, Ifname) ->
  Attr = [{ifname, Ifname}, {ext_mask, 1}],
  Link = {packet, arphrd_netrom, 0, [], [], Attr},
  netlink_request(Pid, getlink, [], Link). 

%% iplink_add(Pid, "vtep1024", "vxlan", 1024, 64000)
iplink_add(Pid, Ifname, Kind, Id, DstPort) ->
  Vxlan = [{id, Id}, {ttl, 0}, {tos, 0}, {learning, 1}, {proxy, 0}, 
           {rsc, 0}, {l2miss, 0}, {l3miss, 0}, {udp_csum, 0},
           {udp_zero_csum6_tx, 0}, {udp_zero_csum6_rx, 0},
           {remcsum_tx, 0}, {remcsum_rx, 0}, {port, DstPort}],
  LinkInfo = [{kind, Kind}, {data, Vxlan}],
  Attr = [{ifname, Ifname}, {linkinfo, LinkInfo}],
  Link = {
    _Family = inet,
    _Type = arphrd_netrom,
    _Ifindex = 0,
    _Flags = [],
    _Change = [],
    Attr},
  netlink_request(Pid, newlink, [create, excl], Link).

%% iplink_set(Pid, {16#70,16#b3,16#d5,16#80,16#00,16#01}, "vtep1024").
iplink_set(Pid, Lladdr, Ifname) ->
 Attr = [{address, Lladdr}],
 Ifindex = if_nametoindex(Ifname),
 Link = {
   _Family = inet,
   _Type = arphrd_netrom,
   _Ifindex = Ifindex,
   _Flags = [1],
   _Change = [1],
   Attr},
 netlink_request(Pid, newlink, [], Link).

%% iprule_show(Pid) ->
%%   [...., {rtnetlink,newrule,[multi],6,31030,
%%       {inet,0,8,0,42,unspec,universe,unicast,[],
%%          [{table,42},{priority,32765},{src,{9,0,0,0}}]}}, ....]
iprule_show(Pid) ->
 Attr = [{29, <<1:32/native-integer>>}], %% [{ext_mask, 1}] 
 Rule = {inet, 0, 0, 0, 0, 0, 0, 0, [], Attr},
 netlink_request(Pid, getrule, [root, match], Rule).

%% iprule_add(Pid, {9,0,0,0}, 8, 42).
iprule_add(Pid, Src, SrcPrefixLen, Table) ->
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
 netlink_request(Pid, newrule, [create, excl], Rule).

make_iprule(Src, SrcPrefixLen, Table) ->
    {inet,0,SrcPrefixLen,0,Table,unspec,universe,unicast,[], [{src, Src}]}.

is_iprule_present([], _) ->
  false;
is_iprule_present([{rtnetlink, newrule, _, _, _, ParsedRule}|Rules], Rule) ->
  case match_iprules(Rule, ParsedRule) of
      matched -> true;
      not_matched -> is_iprule_present(Rules, Rule)
  end.

match_iprules({inet, 0, SrcPrefixLen, 0, Table, unspec,universe,unicast,[], [{src, Src}]},
  {inet, 0, SrcPrefixLen, 0, Table, unspec,universe,unicast,[], Prop}) ->
  case proplists:get_value(src, Prop) of
      Src -> matched;
      _ -> not_matched
  end;
match_iprules(_,_) ->
  not_matched.

%% ipaddr_add(Pid, {44,128,0,1}, 32, "vtep1024"). 
ipaddr_replace(Pid, IP, PrefixLen, Ifname) ->
 Attr = [{local, IP},{address, IP}],
 Ifindex = if_nametoindex(Ifname),
 Msg = {
   _Family = inet, 
   _PrefixLen = PrefixLen, 
   _Flags = 0, 
   _Scope = 0, 
   _Ifindex = Ifindex, 
   Attr},
 netlink_request(Pid, newaddr, [create, replace], Msg). 


real_if_nametoindex(IfName) ->
  {ok, Idx} = gen_netlink_client:if_nametoindex(IfName),
  Idx.

-ifdef(TEST_OR_DEV).
netlink_request(Pid, Type, Flags, Msg) ->
  Uid = list_to_integer(string:strip(os:cmd("id -u"), right, $\n)),
  case Uid of
    0 -> %% root 
      gen_netlink_client:rtnl_request(Pid, Type, Flags, Msg);
    _ ->  
      io:format("Would run fun ~p with flags ~p and argument ~p~n", [Type, Flags, Msg]),
      {ok, []}
  end.

if_nametoindex(Ifname) ->
  Uid = list_to_integer(string:strip(os:cmd("id -u"), right, $\n)),
  case Uid of
     0 -> real_if_nametoindex(Ifname);
     Uid -> Uid
  end.

-else.

netlink_request(Pid, Type, Flags, Msg) ->
  gen_netlink_client:rtnl_request(Pid, Type, Flags, Msg).

if_nametoindex(Ifname) ->
  real_if_nametoindex(Ifname).
-endif.
