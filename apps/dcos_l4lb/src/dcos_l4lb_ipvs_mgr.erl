%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Nov 2016 7:35 AM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_ipvs_mgr).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

-export([get_dests/3,
         add_dest/7,
         remove_dest/7,
         get_services/2,
         add_service/5,
         remove_service/5,
         service_address/1,
         destination_address/2,
         add_netns/2,
         remove_netns/2,
         init_metrics/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    netns :: map(),
    family
}).
-type state() :: #state{}.
-include_lib("gen_netlink/include/netlink.hrl").
-include("dcos_l4lb.hrl").

-define(IP_VS_CONN_F_FWD_MASK, 16#7).       %%  mask for the fwd methods
-define(IP_VS_CONN_F_MASQ, 16#0).           %%  masquerading/NAT
-define(IP_VS_CONN_F_LOCALNODE, 16#1).      %%  local node
-define(IP_VS_CONN_F_TUNNEL, 16#2).         %%  tunneling
-define(IP_VS_CONN_F_DROUTE, 16#3).         %%  direct routing
-define(IP_VS_CONN_F_BYPASS, 16#4).         %%  cache bypass
-define(IP_VS_CONN_F_SYNC, 16#20).          %%  entry created by sync
-define(IP_VS_CONN_F_HASHED, 16#40).        %%  hashed entry
-define(IP_VS_CONN_F_NOOUTPUT, 16#80).      %%  no output packets
-define(IP_VS_CONN_F_INACTIVE, 16#100).     %%  not established
-define(IP_VS_CONN_F_OUT_SEQ, 16#200).      %%  must do output seq adjust
-define(IP_VS_CONN_F_IN_SEQ, 16#400).       %%  must do input seq adjust
-define(IP_VS_CONN_F_SEQ_MASK, 16#600).     %%  in/out sequence mask
-define(IP_VS_CONN_F_NO_CPORT, 16#800).     %%  no client port set yet
-define(IP_VS_CONN_F_TEMPLATE, 16#1000).    %%  template, not connection
-define(IP_VS_CONN_F_ONE_PACKET, 16#2000).  %%  forward only one packet

-define(IP_VS_SVC_F_PERSISTENT, 16#1).          %% persistent port */
-define(IP_VS_SVC_F_HASHED,     16#2).          %% hashed entry */
-define(IP_VS_SVC_F_ONEPACKET,  16#4).          %% one-packet scheduling */
-define(IP_VS_SVC_F_SCHED1,     16#8).          %% scheduler flag 1 */
-define(IP_VS_SVC_F_SCHED2,     16#10).          %% scheduler flag 2 */
-define(IP_VS_SVC_F_SCHED3,     16#20).          %% scheduler flag 3 */

-define(IPVS_PROTOCOLS, [tcp, udp]). %% protocols to query gen_netlink for
-define(ADDR_FAMILIES, [inet, inet6]).


-type service() :: term().
-type dest() :: term().
-export_type([service/0, dest/0]).

%%%===================================================================
%%% API
%%%===================================================================

-spec(get_services(Pid :: pid(), Namespace :: term()) -> [service()]).
get_services(Pid, Namespace) ->
    gen_server:call(Pid, {get_services, Namespace}).

-spec(add_service(Pid :: pid(), IP :: inet:ip_address(), Port :: inet:port_number(),
                  Protocol :: protocol(), Namespace :: term()) -> ok | error).
add_service(Pid, IP, Port, Protocol, Namespace) ->
    prometheus_summary:observe_duration(
        l4lb, ipvs_updates_seconds, [],
        fun () -> gen_server:call(Pid, {add_service, IP, Port, Protocol, Namespace}) end).

-spec(remove_service(Pid :: pid(), IP :: inet:ip_address(),
                     Port :: inet:port_number(),
                     Protocol :: protocol(), Namespace :: term()) -> ok | error).
remove_service(Pid, IP, Port, Protocol, Namespace) ->
    prometheus_summary:observe_duration(
        l4lb, ipvs_updates_seconds, [],
        fun () -> gen_server:call(Pid, {remove_service, IP, Port, Protocol, Namespace}) end).

-spec(get_dests(Pid :: pid(), Service :: service(), Namespace :: term()) -> [dest()]).
get_dests(Pid, Service, Namespace) ->
    gen_server:call(Pid, {get_dests, Service, Namespace}).

-spec(remove_dest(Pid :: pid(), ServiceIP :: inet:ip_address(),
                  ServicePort :: inet:port_number(),
                  DestIP :: inet:ip_address(), DestPort :: inet:port_number(),
                  Protocol :: protocol(), Namespace :: term()) -> ok | error).
remove_dest(Pid, ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace) ->
    prometheus_summary:observe_duration(
        l4lb, ipvs_updates_seconds, [],
        fun () ->
            gen_server:call(Pid, {remove_dest, ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace})
        end).

-spec(add_dest(Pid :: pid(), ServiceIP :: inet:ip_address(), ServicePort :: inet:port_number(),
               DestIP :: inet:ip_address(), DestPort :: inet:port_number(),
               Protocol :: protocol(), Namespace :: term()) -> ok | error).
add_dest(Pid, ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace) ->
    prometheus_summary:observe_duration(
        l4lb, ipvs_updates_seconds, [],
        fun () ->
            gen_server:call(Pid, {add_dest, ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace})
        end).

add_netns(Pid, UpdateValue) ->
    prometheus_summary:observe_duration(
        l4lb, ipvs_updates_seconds, [],
        fun () -> gen_server:call(Pid, {add_netns, UpdateValue}) end).

remove_netns(Pid, UpdateValue) ->
    prometheus_summary:observe_duration(
        l4lb, ipvs_updates_seconds, [],
        fun () -> gen_server:call(Pid, {remove_netns, UpdateValue}) end).

%% @doc Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, Pid} = gen_netlink_client:start_link(),
    {ok, Family} = gen_netlink_client:get_family(Pid, "IPVS"),
    {ok, #state{netns = #{host => Pid}, family = Family}}.

handle_call({get_services, Namespace}, _From, State) ->
    Reply = handle_get_services(Namespace, State),
    {reply, Reply, State};
handle_call({add_service, IP, Port, Protocol, Namespace}, _From, State) ->
    Reply = handle_add_service(IP, Port, Protocol, Namespace, State),
    {reply, Reply, State};
handle_call({remove_service, IP, Port, Protocol, Namespace}, _From, State) ->
    Reply = handle_remove_service(IP, Port, Protocol, Namespace, State),
    {reply, Reply, State};
handle_call({get_dests, Service, Namespace}, _From, State) ->
    Reply = handle_get_dests(Service, Namespace, State),
    {reply, Reply, State};
handle_call({add_dest, ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace}, _From, State) ->
    Reply = handle_add_dest(ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace, State),
    {reply, Reply, State};
handle_call({remove_dest, ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace}, _From, State) ->
    Reply = handle_remove_dest(ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace, State),
    {reply, Reply, State};
handle_call({add_netns, UpdateValue}, _From, State0) ->
    {Reply, State1} = handle_add_netns(UpdateValue, State0),
    {reply, Reply, State1};
handle_call({remove_netns, UpdateValue}, _From, State0) ->
    {Reply, State1} = handle_remove_netns(UpdateValue, State0),
    {reply, Reply, State1}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(service_address(service()) -> {family(), {protocol(), inet:ip_address(), inet:port_number()}}).
service_address(Service) ->
    AF = proplists:get_value(address_family, Service),
    Protocol = netlink_codec:protocol_to_atom(proplists:get_value(protocol, Service)),
    AddressBin = proplists:get_value(address, Service),
    Port = proplists:get_value(port, Service),
    Family = netlink_codec:family_to_atom(AF),
    InetAddr = address_to_ip(Family, AddressBin),
    {AF, {Protocol, InetAddr, Port}}.

-spec(destination_address(family(), Destination :: dest()) -> {inet:ip_address(), inet:port_number()}).
destination_address(AF, Destination) ->
    AddressBin = proplists:get_value(address, Destination),
    Port = proplists:get_value(port, Destination),
    Family = netlink_codec:family_to_atom(AF),
    InetAddr = address_to_ip(Family, AddressBin),
    {InetAddr, Port}.


-spec(handle_get_services(Namespace :: term(), State :: state()) -> [service()]).
handle_get_services(Namespace, State = #state{netns = NetnsMap}) ->
    Pid = maps:get(Namespace, NetnsMap),
    Params = [{AF, P} || AF <- ?ADDR_FAMILIES, P <- ?IPVS_PROTOCOLS],
    lists:foldl(
      fun({AddrFamily, Proto}, Acc) ->
              Services = handle_get_services(AddrFamily, Proto, Pid, State),
              Acc ++ Services
      end, [], Params).

-spec(handle_get_services(AddressFamily :: family(), Protocol :: protocol(),
                          Namespace :: term(), State :: state()) -> [service()]).
handle_get_services(AddressFamily, Protocol, Pid, #state{family = Family}) ->
    AddressFamily1 = netlink_codec:family_to_int(AddressFamily),
    Protocol1 = netlink_codec:protocol_to_int(Protocol),
    Message =
        #get_service{
           request =
               [{service,
                 [{address_family, AddressFamily1},
                  {protocol, Protocol1}
                 ]}
               ]},
    {ok, Replies} = gen_netlink_client:request(Pid, Family, ipvs, [root, match], Message),
    [proplists:get_value(service, MaybeService)
     || #netlink{msg = #new_service{request = MaybeService}}
          <- Replies, proplists:is_defined(service, MaybeService)].

-spec(handle_remove_service(IP :: inet:ip_address(), Port :: inet:port_number(),
                            Protocol :: protocol(), Namespace :: term(),
                            State :: state()) -> ok | error).
handle_remove_service(IP, Port, Protocol, Namespace, State) ->
    Protocol1 = netlink_codec:protocol_to_int(Protocol),
    Service = ip_to_address(IP) ++ [{port, Port}, {protocol, Protocol1}],
    handle_remove_service(Service, Namespace, State).

-spec(handle_remove_service(Service :: service(), Namespace :: term(), State :: state()) -> ok | error).
handle_remove_service(Service, Namespace, #state{netns = NetnsMap, family = Family}) ->
    lager:info("Namespace: ~p, Removing Service: ~p", [Namespace, Service]),
    Pid = maps:get(Namespace, NetnsMap),
    case gen_netlink_client:request(Pid, Family, ipvs, [], #del_service{request = [{service, Service}]}) of
        {ok, _} -> ok;
        _ -> error
    end.

-spec(handle_add_service(IP :: inet:ip_address(), Port :: inet:port_number(),
                         Protocol :: protocol(), Namespace :: term(), State :: state()) -> ok | error).
handle_add_service(IP, Port, Protocol, Namespace, #state{netns = NetnsMap, family = Family}) ->
    Flags = 0,
    Pid = maps:get(Namespace, NetnsMap),
    Service0 = [
        {protocol, netlink_codec:protocol_to_int(Protocol)},
        {port, Port},
        {sched_name, "wlc"},
        {netmask, netmask_by_addrtype(IP)},
        {flags, Flags, 16#ffffffff},
        {timeout, 0}
    ],
    Service1 = ip_to_address(IP) ++ Service0,
    lager:info("Namespace: ~p, Adding Service: ~p", [Namespace, Service1]),
    case gen_netlink_client:request(Pid, Family, ipvs, [], #new_service{request = [{service, Service1}]}) of
        {ok, _} -> ok;
        _ -> error
    end.

-spec(handle_get_dests(Service :: service(), Namespace :: term(), State :: state()) -> [dest()]).
handle_get_dests(Service, Namespace, #state{netns = NetnsMap, family = Family}) ->
    Pid = maps:get(Namespace, NetnsMap),
    Message = #get_dest{request = [{service, Service}]},
    {ok, Replies} = gen_netlink_client:request(Pid, Family, ipvs, [root, match], Message),
    [proplists:get_value(dest, MaybeDest) || #netlink{msg = #new_dest{request = MaybeDest}} <- Replies,
        proplists:is_defined(dest, MaybeDest)].

-spec(handle_add_dest(ServiceIP :: inet:ip_address(), ServicePort :: inet:port_number(),
                      DestIP :: inet:ip_address(), DestPort :: inet:port_number(),
                      Protocol :: protocol(), Namespace :: term(), State :: state()) -> ok | error).
handle_add_dest(ServiceIP, ServicePort, DestIP, DestPort, Protocol,
                Namespace, #state{netns = NetnsMap, family = Family}) ->
    Pid = maps:get(Namespace, NetnsMap),
    Protocol1 = netlink_codec:protocol_to_int(Protocol),
    Service = ip_to_address(ServiceIP) ++ [{port, ServicePort}, {protocol, Protocol1}],
    handle_add_dest(Pid, Service, DestIP, DestPort, Family).

handle_add_dest(Pid, Service, IP, Port, Family) ->
    Base = [{fwd_method, ?IP_VS_CONN_F_MASQ}, {weight, 1}, {u_threshold, 0}, {l_threshold, 0}],
    Dest = [{port, Port}] ++ Base ++ ip_to_address(IP),
    lager:info("Adding backend ~p to service ~p~n", [{IP, Port}, Service]),
    Msg = #new_dest{request = [{dest, Dest}, {service, Service}]},
    case gen_netlink_client:request(Pid, Family, ipvs, [], Msg) of
        {ok, _} -> ok;
        _ -> error
    end.

-spec(handle_remove_dest(ServiceIP :: inet:ip_address(), ServicePort :: inet:port_number(),
                         DestIP :: inet:ip_address(), DestPort :: inet:port_number(),
                         Protocol :: protocol(), Namespace :: term(), State :: state()) -> ok | error).
handle_remove_dest(ServiceIP, ServicePort, DestIP, DestPort, Protocol, Namespace, State) ->
    Protocol1 = netlink_codec:protocol_to_int(Protocol),
    Service = ip_to_address(ServiceIP) ++ [{port, ServicePort}, {protocol, Protocol1}],
    Dest = ip_to_address(DestIP) ++ [{port, DestPort}],
    handle_remove_dest(Service, Dest, Namespace, State).

-spec(handle_remove_dest(Service :: service(), Dest :: dest(), Namespace :: term(), State :: state()) -> ok | error).
handle_remove_dest(Service, Dest, Namespace, #state{netns = NetnsMap, family = Family}) ->
    lager:info("Removing Dest ~p to service ~p~n", [Dest, Service]),
    Pid = maps:get(Namespace, NetnsMap),
    Msg = #del_dest{request = [{dest, Dest}, {service, Service}]},
    case gen_netlink_client:request(Pid, Family, ipvs, [], Msg) of
        {ok, _} -> ok;
        _ -> error
    end.

netmask_by_addrtype(IP) when size(IP) == 4 ->
    16#ffffffff;
netmask_by_addrtype(IP) when size(IP) == 8 ->
    128.

address_to_ip(inet6, <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>) ->
    {A, B, C, D, E, F, G, H};
address_to_ip(inet, <<A, B, C, D, _Rest/binary>>) ->
    {A, B, C, D}.

ip_to_address(IP0) when size(IP0) == 4 ->
    [{address_family, netlink_codec:family_to_int(inet)}, {address, ip_to_address2(IP0)}];
ip_to_address(IP0) when size(IP0) == 8 ->
    [{address_family, netlink_codec:family_to_int(inet6)}, {address, ip_to_address2(IP0)}].

ip_to_address2({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>;
ip_to_address2(IP0) ->
    IP1 = tuple_to_list(IP0),
    IP2 = binary:list_to_bin(IP1),
    Padding = 8 * (16 - size(IP2)),
    <<IP2/binary, 0:Padding/integer>>.

handle_add_netns(Netnslist, State = #state{netns = NetnsMap0}) ->
    NetnsMap1 = lists:foldl(fun maybe_add_netns/2, maps:new(), Netnslist),
    NetnsMap2 = maps:merge(NetnsMap0, NetnsMap1),
    {maps:keys(NetnsMap1), State#state{netns = NetnsMap2}}.

handle_remove_netns(Netnslist, State = #state{netns = NetnsMap0}) ->
    NetnsMap1 = lists:foldl(fun maybe_remove_netns/2, NetnsMap0, Netnslist),
    RemovedNs = lists:subtract(maps:keys(NetnsMap0), maps:keys(NetnsMap1)),
    {RemovedNs, State#state{netns = NetnsMap1}}.

maybe_add_netns(Netns = #netns{id = Id}, NetnsMap) ->
    maybe_add_netns(maps:is_key(Id, NetnsMap), Netns, NetnsMap).

maybe_add_netns(true, _, NetnsMap) ->
    NetnsMap;
maybe_add_netns(false, #netns{id = Id, ns = Namespace}, NetnsMap) ->
    case gen_netlink_client:start_link(netns, binary_to_list(Namespace)) of
        {ok, Pid} ->
            maps:put(Id, Pid, NetnsMap);
        {error, Reason} ->
            lager:error("Couldn't create route netlink client for ~p due to ~p", [Id, Reason]),
            NetnsMap
    end.

maybe_remove_netns(Netns = #netns{id = Id}, NetnsMap) ->
    maybe_remove_netns(maps:is_key(Id, NetnsMap), Netns, NetnsMap).

maybe_remove_netns(true, #netns{id = Id}, NetnsMap) ->
    Pid = maps:get(Id, NetnsMap),
    erlang:unlink(Pid),
    gen_netlink_client:stop(Pid),
    maps:remove(Id, NetnsMap);
maybe_remove_netns(false, _, NetnsMap) ->
    NetnsMap.

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(init_metrics() -> ok).
init_metrics() ->
    prometheus_summary:declare([
        {registry, l4lb},
        {name, ipvs_updates_seconds},
        {help, "The time spent updating ipvs configuration."}]),
    ok.

%%%===================================================================
%%% Test functions
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ip_to_address2_test() ->
    IP = {16#fd01, 16#0, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1},
    IP0 = ip_to_address2(IP),
    Expected = <<253, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>,
    ?assertEqual(Expected, IP0).

destination_address_test_() ->
    D = [{address, <<10, 10, 0, 83, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
         {port, 9042},
         {fwd_method, 0},
         {weight, 1},
         {u_threshold, 0},
         {l_threshold, 0},
         {active_conns, 0},
         {inact_conns, 0},
         {persist_conns, 0},
         {stats, [{conns, 0},
                 {inpkts, 0},
                 {outpkts, 0},
                 {inbytes, 0},
                 {outbytes, 0},
                 {cps, 0},
                 {inpps, 0},
                 {outpps, 0},
                 {inbps, 0},
                 {outbps, 0}]}],
    DAddr = {{10, 10, 0, 83}, 9042},
    AF = netlink_codec:family_to_int(inet),
    [?_assertEqual(DAddr, destination_address(AF, D))].

service_address_tcp_test_() ->
    service_address_(tcp).

service_address_udp_test_() ->
    service_address_(udp).

service_address_(Protocol) ->
    AF = netlink_codec:family_to_int(inet),
    S = [{address_family, AF},
         {protocol, proto_num(Protocol)},
         {address, <<11, 197, 245, 133, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
         {port, 9042},
         {sched_name, "wlc"},
         {flags, 2, 4294967295},
         {timeout, 0},
         {netmask, 4294967295},
         {stats, [{conns, 0},
                 {inpkts, 0},
                 {outpkts, 0},
                 {inbytes, 0},
                 {outbytes, 0},
                 {cps, 0},
                 {inpps, 0},
                 {outpps, 0},
                 {inbps, 0},
                 {outbps, 0}]}],
    SAddr = {AF, {Protocol, {11, 197, 245, 133}, 9042}},
    [?_assertEqual(SAddr, service_address(S))].

proto_num(tcp) -> 6;
proto_num(udp) -> 17.
-endif.
