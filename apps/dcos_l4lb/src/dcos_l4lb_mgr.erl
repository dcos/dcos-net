-module(dcos_l4lb_mgr).
-behaviour(gen_server).

-include_lib("stdlib/include/ms_transform.hrl").
-include("dcos_l4lb_lashup.hrl").
-include("dcos_l4lb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
    push_vips/1,
    push_netns/2,
    local_port_mappings/1
]).

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-record(state, {
    % pids and refs
    ipvs_mgr :: pid(),
    route_mgr :: pid(),
    netns_mgr :: pid(),
    route_ref :: reference(),
    nodes_ref :: reference(),
    recon_ref :: reference(),
    % data
    tree = #{} :: lashup_gm_route:tree(),
    nodes = #{} :: #{inet:ip4_address() => node()},
    netns = [host] :: [host | netns()],
    % vips
    vips = [] :: [{key(), [backend()]}],
    prev_ipvs = [] :: [{key(), [ipport()]}],
    prev_routes = [] :: [inet:ip_address()]
}).
-type state() :: #state{}.

-type key() :: dcos_l4lb_mesos_poller:key().
-type backend() :: dcos_l4lb_mesos_poller:backend().
-type ipport() :: {inet:ip_address(), inet:port_number()}.

-spec(push_vips(VIPs :: [{Key, [Backend]}]) -> ok
    when Key :: dcos_l4lb_mesos_poller:key(),
         Backend :: dcos_l4lb_mesos_poller:backend()).
push_vips(VIPs) ->
    gen_server:cast(?MODULE, {vips, VIPs}).

-spec(push_netns(EventType, [netns()]) -> ok
    when EventType :: add_netns | remove_netns | reconcile_netns).
push_netns(EventType, EventContent) ->
    gen_server:cast(?MODULE, {netns, {self(), EventType, EventContent}}).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    init_local_port_mappings(),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! init,
    {ok, []}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({vips, VIPs}, State) ->
    {noreply, handle_vips(VIPs, State)};
handle_cast({netns, Event}, State) ->
    {noreply, handle_netns_event(Event, State)};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, []) ->
    {noreply, handle_init()};
handle_info({lashup_gm_route_events, Event}, State) ->
    {noreply, handle_gm_event(Event, State)};
handle_info({lashup_kv_events, Event}, State) ->
    {noreply, handle_kv_event(Event, State)};
handle_info({timeout, _Ref, reconcile}, State) ->
    {noreply, handle_reconcile(State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Events functions
%%%===================================================================

-spec(handle_init() -> state()).
handle_init() ->
    {ok, IPVSMgr} = dcos_l4lb_ipvs_mgr:start_link(),
    {ok, RouteMgr} = dcos_l4lb_route_mgr:start_link(),
    {ok, NetNSMgr} = dcos_l4lb_netns_watcher:start_link(),

    MatchSpec = ets:fun2ms(fun ({?NODEMETADATA_KEY}) -> true end),
    {ok, NodesRef} = lashup_kv_events_helper:start_link(MatchSpec),
    {ok, RouteRef} = lashup_gm_route_events:subscribe(),
    ReconRef = start_reconcile_timer(),

    #state{ipvs_mgr=IPVSMgr, route_mgr=RouteMgr, netns_mgr=NetNSMgr,
           route_ref=RouteRef, nodes_ref=NodesRef, recon_ref=ReconRef}.

-spec(handle_gm_event(Event :: map(), state()) -> state()).
handle_gm_event(#{ref := Ref, tree := Tree},
                #state{route_ref=Ref}=State) ->
    State#state{tree=Tree};
handle_gm_event(_Event, State) ->
    State.

-spec(handle_kv_event(Event :: map(), state()) -> state()).
handle_kv_event(#{ref := Ref, value := Value},
                #state{nodes_ref=Ref}=State) ->
    Nodes = [{IP, Node} || {?LWW_REG(IP), Node} <- Value],
    State#state{nodes=maps:from_list(Nodes)};
handle_kv_event(_Event, State) ->
    State.

-spec(handle_netns_event({pid(), EventType, [netns()]}, state()) -> state()
    when EventType :: add_netns | remove_netns | reconcile_netns).
handle_netns_event({Pid, remove_netns, EventContent},
                #state{netns_mgr=Pid}=State) ->
    handle_netns_event(remove_netns, EventContent, State);
handle_netns_event({Pid, EventType, EventContent},
                #state{netns_mgr=Pid}=State) ->
    State0 = handle_netns_event(EventType, EventContent, State),
    handle_reconcile(State0);
handle_netns_event(_Event, State) ->
    State.

-spec(handle_vips([{key(), [backend()]}], state()) -> state()).
handle_vips(VIPs, State) ->
    handle_vips_imp(VIPs, State).

-spec(handle_reconcile(state()) -> state()).
handle_reconcile(#state{vips=VIPs, recon_ref=Ref}=State) ->
    erlang:cancel_timer(Ref),
    State0 = handle_reconcile(VIPs, State),
    Ref0 = start_reconcile_timer(),
    State0#state{recon_ref=Ref0}.

-spec(start_reconcile_timer() -> reference()).
start_reconcile_timer() ->
    Timeout = application:get_env(dcos_l4lb, reconcile_timeout, 30000),
    erlang:start_timer(Timeout, self(), reconcile).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(handle_reconcile([{key(), [backend()]}], state()) -> state()).
handle_reconcile(VIPs, #state{route_mgr=RouteMgr, ipvs_mgr=IPVSMgr,
        tree=Tree, nodes=Nodes, netns=Namespaces}=State) ->
    % If everything is ok this function is silent and changes nothing.
    VIPs0 = vips_port_mappings(VIPs),
    VIPs1 = healthy_vips(VIPs0, Nodes, Tree),
    VIPsP = prepare_vips(VIPs1),
    Routes = get_vip_routes(VIPs1),
    lists:foreach(fun (NetNs) ->
        PrevRoutes = get_routes(RouteMgr, NetNs),
        DiffRoutes = dcos_net_utils:complement(Routes, PrevRoutes),
        ok = apply_routes_diff(RouteMgr, NetNs, DiffRoutes),

        PrevVIPsP = get_vips(IPVSMgr, NetNs),
        DiffVIPs = diff(PrevVIPsP, VIPsP),
        ok = apply_vips_diff(IPVSMgr, NetNs, DiffVIPs)
    end, Namespaces),
    State#state{prev_ipvs=VIPs1, prev_routes=Routes}.

-spec(handle_vips_imp([{key(), [backend()]}], state()) -> state()).
handle_vips_imp(VIPs, #state{route_mgr=RouteMgr, ipvs_mgr=IPVSMgr,
        tree=Tree, nodes=Nodes, netns=Namespaces,
        prev_ipvs=PrevVIPs, prev_routes=PrevRoutes}=State) ->
    VIPs0 = vips_port_mappings(VIPs),
    VIPs1 = healthy_vips(VIPs0, Nodes, Tree),
    DiffVIPs = diff(prepare_vips(PrevVIPs), prepare_vips(VIPs1)),

    Routes = get_vip_routes(VIPs1),
    DiffRoutes = dcos_net_utils:complement(Routes, PrevRoutes),

    lists:foreach(fun (NetNs) ->
        ok = apply_routes_diff(RouteMgr, NetNs, DiffRoutes),
        ok = apply_vips_diff(IPVSMgr, NetNs, DiffVIPs)
    end, Namespaces),
    State#state{vips=VIPs, prev_ipvs=VIPs1, prev_routes=Routes}.

%%%===================================================================
%%% Routes functions
%%%===================================================================

-type diff_routes() :: {[inet:ip_address()], [inet:ip_address()]}.

-spec(apply_routes_diff(pid(), NetNs, diff_routes()) -> ok
    when NetNs :: netns() | host).
apply_routes_diff(RouteMgr, NetNs, {ToAdd, ToDel}) ->
    dcos_l4lb_route_mgr:add_routes(RouteMgr, ToAdd, NetNs),
    dcos_l4lb_route_mgr:remove_routes(RouteMgr, ToDel, NetNs).

-spec(get_routes(pid(), netns() | host) -> [inet:ip_address()]).
get_routes(RouteMgr, NetNs) ->
    dcos_l4lb_route_mgr:get_routes(RouteMgr, NetNs).

-spec(get_vip_routes(VIPs :: [{key(), [backend()]}]) -> [inet:ip_address()]).
get_vip_routes(VIPs) ->
    lists:usort([IP || {{_Proto, IP, _Port}, _Backends} <- VIPs]).

%%%===================================================================
%%% IPVS functions
%%%===================================================================

-spec(prepare_vips([{key(), [backend()]}]) -> [{key(), [ipport()]}]).
prepare_vips(VIPs) ->
    lists:map(fun ({VIP, BEs}) ->
        {VIP, [BE || {_AgentIP, BE} <- BEs]}
    end, VIPs).

-spec(get_vips(pid(), netns() | host) -> [{key(), [ipport()]}]).
get_vips(IPVSMgr, NetNs) ->
    Services = get_vip_services(IPVSMgr, NetNs),
    lists:map(fun (S) -> get_vip(IPVSMgr, NetNs, S) end, Services).

-spec(get_vip_services(pid(), netns() | host) -> [Service]
    when Service :: dcos_l4lb_ipvs_mgr:service()).
get_vip_services(IPVSMgr, NetNs) ->
    Services = dcos_l4lb_ipvs_mgr:get_services(IPVSMgr, NetNs),
    FVIPs = lists:map(fun dcos_l4lb_ipvs_mgr:service_address/1, Services),
    maps:values(maps:from_list(lists:zip(FVIPs, Services))).

-spec(get_vip(pid(), netns() | host, Service) -> {key(), [ipport()]}
    when Service :: dcos_l4lb_ipvs_mgr:service()).
get_vip(IPVSMgr, NetNs, Service) ->
    {Family, VIP} = dcos_l4lb_ipvs_mgr:service_address(Service),
    Dests = dcos_l4lb_ipvs_mgr:get_dests(IPVSMgr, Service, NetNs),
    Backends =
        lists:map(fun (Dest) ->
            dcos_l4lb_ipvs_mgr:destination_address(Family, Dest)
        end, Dests),
    {VIP, lists:usort(Backends)}.

%%%===================================================================
%%% IPVS Apply functions
%%%===================================================================

-type diff_vips() :: {ToAdd :: [{key(), [ipport()]}],
                      ToDel :: [{key(), [ipport()]}],
                      ToMod :: [{key(), [ipport()], [ipport()]}]}.

-spec(apply_vips_diff(pid(), netns() | host, diff_vips()) -> ok).
apply_vips_diff(IPVSMgr, NetNs, {ToAdd, ToDel, ToMod}) ->
    lists:foreach(fun (VIP) ->
        vip_del(IPVSMgr, NetNs, VIP)
    end, ToDel),
    lists:foreach(fun (VIP) ->
        vip_add(IPVSMgr, NetNs, VIP)
    end, ToAdd),
    lists:foreach(fun (VIP) ->
        vip_mod(IPVSMgr, NetNs, VIP)
    end, ToMod).

-spec(vip_add(pid(), netns() | host, {key(), [ipport()]}) -> ok).
vip_add(IPVSMgr, NetNs, {{Protocol, IP, Port}, BEs}) ->
    dcos_l4lb_ipvs_mgr:add_service(IPVSMgr, IP, Port, Protocol, NetNs),
    lists:foreach(fun ({BEIP, BEPort}) ->
        dcos_l4lb_ipvs_mgr:add_dest(
            IPVSMgr, IP, Port,
            BEIP, BEPort,
            Protocol, NetNs)
    end, BEs).

-spec(vip_del(pid(), netns() | host, {key(), [ipport()]}) -> ok).
vip_del(IPVSMgr, NetNs, {{Protocol, IP, Port}, _BEs}) ->
    dcos_l4lb_ipvs_mgr:remove_service(IPVSMgr, IP, Port, Protocol, NetNs).

-spec(vip_mod(pid(), netns() | host, {key(), [ipport()], [ipport()]}) -> ok).
vip_mod(IPVSMgr, NetNs, {{Protocol, IP, Port}, ToAdd, ToDel}) ->
    lists:foreach(fun ({BEIP, BEPort}) ->
        dcos_l4lb_ipvs_mgr:add_dest(
            IPVSMgr, IP, Port,
            BEIP, BEPort,
            Protocol, NetNs)
    end, ToAdd),
    lists:foreach(fun ({BEIP, BEPort}) ->
        dcos_l4lb_ipvs_mgr:remove_dest(
            IPVSMgr, IP, Port,
            BEIP, BEPort,
            Protocol, NetNs)
    end, ToDel).

%%%===================================================================
%%% Diff functions
%%%===================================================================

%% @doc Return {A\B, B\A, [{Key, Va\Vb, Vb\Va}]}
-spec(diff([{A, B}], [{A, B}]) -> {[{A, B}], [{A, B}], [{A, B, B}]}
    when A :: term(), B :: term()).
diff(ListA, ListB) ->
    diff(lists:sort(ListA),
         lists:sort(ListB),
         [], [], []).

-spec(diff([{A, B}], [{A, B}], [{A, B}], [{A, B}], [{A, B, B}]) ->
    {[{A, B}], [{A, B}], [{A, B, B}]} when A :: term(), B :: term()).
diff([A|ListA], [A|ListB], Acc, Bcc, Mcc) ->
    diff(ListA, ListB, Acc, Bcc, Mcc);
diff([{Key, Va}|ListA], [{Key, Vb}|ListB], Acc, Bcc, Mcc) ->
    {Ma, Mb} = dcos_net_utils:complement(Vb, Va),
    diff(ListA, ListB, Acc, Bcc, [{Key, Ma, Mb}|Mcc]);
diff([A|_]=ListA, [B|ListB], Acc, Bcc, Mcc) when A > B ->
    diff(ListA, ListB, [B|Acc], Bcc, Mcc);
diff([A|ListA], [B|_]=ListB, Acc, Bcc, Mcc) when A < B ->
    diff(ListA, ListB, Acc, [A|Bcc], Mcc);
diff([], ListB, Acc, Bcc, Mcc) ->
    {ListB ++ Acc, Bcc, Mcc};
diff(ListA, [], Acc, Bcc, Mcc) ->
    {Acc, ListA ++ Bcc, Mcc}.

%%%===================================================================
%%% Reachability functions
%%%===================================================================

-spec(healthy_vips(VIPs, Nodes, Tree) -> VIPs
    when VIPs :: [{key(), [backend()]}],
         Nodes :: #{inet:ip4_address() => node()},
         Tree :: lashup_gm_route:tree()).
healthy_vips(VIPs, Nodes, Tree)
        when map_size(Tree) =:= 0;
             map_size(Nodes) =:= 0 ->
    VIPs;
healthy_vips(VIPs, Nodes, Tree) ->
    Agents = agents(VIPs, Nodes, Tree),
    lists:map(fun ({VIP, BEs}) ->
        {VIP, healthy_backends(BEs, Agents)}
    end, VIPs).

-spec(agents(VIPs, Nodes, Tree) -> #{inet:ip4_address() => boolean()}
    when VIPs :: [{key(), [backend()]}],
         Nodes :: #{inet:ip4_address() => node()},
         Tree :: lashup_gm_route:tree()).
agents(VIPs, Nodes, Tree) ->
    AgentIPs =
        lists:flatmap(fun ({_VIP, BEs}) ->
            [AgentIP || {AgentIP, _BE} <- BEs]
        end, VIPs),
    AgentIPs0 = lists:usort(AgentIPs),
    Result = [{IP, is_reachable(IP, Nodes, Tree)} || IP <- AgentIPs0],
    maps:from_list(Result).

-spec(healthy_backends([backend()], Agents) -> [backend()]
    when Agents :: #{inet:ip4_address() => boolean()}).
healthy_backends(BEs, Agents) ->
    case [BE || BE={IP, _BE} <- BEs, maps:get(IP, Agents)] of
        [] -> BEs;
        BEs0 -> BEs0
    end.

-spec(is_reachable(inet:ip4_address(), Nodes, Tree) -> boolean()
    when Nodes :: #{inet:ip4_address() => node()},
         Tree :: lashup_gm_route:tree()).
is_reachable(AgentIP, Nodes, Tree) ->
    case maps:find(AgentIP, Nodes) of
        {ok, Node} ->
            Distance = lashup_gm_route:distance(Node, Tree),
            Distance =/= infinity;
        error ->
            false
    end.

%%%===================================================================
%%% Network Namespace functions
%%%===================================================================

-spec(handle_netns_event(EventType, [netns()], state()) -> state()
    when EventType :: add_netns | remove_netns | reconcile_netns).
handle_netns_event(remove_netns, ToDel,
        #state{ipvs_mgr=IPVSMgr, route_mgr=RouteMgr, netns=Prev}=State) ->
    Namespaces = dcos_l4lb_route_mgr:remove_netns(RouteMgr, ToDel),
    Namespaces = dcos_l4lb_route_mgr:remove_netns(IPVSMgr, ToDel),
    Result = ordsets:subtract(Prev, ordsets:from_list(Namespaces)),
    State#state{netns=Result};
handle_netns_event(add_netns, ToAdd,
        #state{ipvs_mgr=IPVSMgr, route_mgr=RouteMgr, netns=Prev}=State) ->
    Namespaces = dcos_l4lb_route_mgr:add_netns(RouteMgr, ToAdd),
    Namespaces = dcos_l4lb_ipvs_mgr:add_netns(IPVSMgr, ToAdd),
    Result = ordsets:union(ordsets:from_list(Namespaces), Prev),
    State#state{netns=Result};
handle_netns_event(reconcile_netns, Namespaces, State) ->
    handle_netns_event(add_netns, Namespaces, State).

%%%===================================================================
%%% Local Port Mappings functions
%%%===================================================================

-spec(vips_port_mappings(VIPs) -> VIPs
    when VIPs :: [{key(), [backend()]}]).
vips_port_mappings(VIPs) ->
    PMs = local_port_mappings(),
    AgentIP = dcos_net_dist:nodeip(),
    % Remove port mappings for local backends.
    lists:map(fun ({{Protocol, VIP, VIPPort}, BEs}) ->
        BEs0 = bes_port_mappings(PMs, Protocol, AgentIP, BEs),
        {{Protocol, VIP, VIPPort}, BEs0}
    end, VIPs).

-spec(bes_port_mappings(PMs, tcp | udp, AgentIP, [backend()]) -> [backend()]
    when PMs :: #{Host => Container},
         AgentIP :: inet:ip4_address(),
         Host :: {tcp | udp, inet:port_number()},
         Container :: {inet:ip_address(), inet:port_number()}).
bes_port_mappings(PMs, Protocol, AgentIP, BEs) ->
    lists:map(
        fun ({BEAgentIP, {BEIP, BEPort}}) when BEIP =:= AgentIP ->
                case maps:find({Protocol, BEPort}, PMs) of
                    {ok, {IP, Port}} -> {BEAgentIP, {IP, Port}};
                    error -> {BEAgentIP, {BEIP, BEPort}}
                end;
            ({BEAgentIP, {BEIP, BEPort}}) ->
                {BEAgentIP, {BEIP, BEPort}}
        end, BEs).

%%%===================================================================
%%% Local Port Mappings API functions
%%%===================================================================

-spec(init_local_port_mappings() -> local_port_mappings).
init_local_port_mappings() ->
    try
        ets:new(local_port_mappings, [public, named_table])
    catch error:badarg ->
        local_port_mappings
    end.

-spec(local_port_mappings([{Host, Container}] | #{Host => Container}) -> true
    when Host :: {tcp | udp, inet:port_number()},
         Container :: {inet:ip_address(), inet:port_number()}).
local_port_mappings(PortMappings) when is_list(PortMappings) ->
    PortMappings0 = maps:from_list(PortMappings),
    local_port_mappings(PortMappings0);
local_port_mappings(PortMappings) ->
    try
        true = ets:insert(local_port_mappings, {pm, PortMappings})
    catch error:badarg ->
        true
    end.

-spec(local_port_mappings() -> #{Host => Container}
    when Host :: {tcp | udp, inet:port_number()},
         Container :: {inet:ip_address(), inet:port_number()}).
local_port_mappings() ->
    try ets:lookup(local_port_mappings, pm) of
        [{pm, PortMappings}] ->
            PortMappings;
        [] ->
            #{}
    catch error:badarg ->
        #{}
    end.

-ifdef(TEST).

diff_simple_test() ->
    ?assertEqual(
        {[], [], []},
        diff([], [])),
    ?assertEqual(
        {[], [], [{a, [4], [1]}]},
        diff([{a, [1, 2, 3]}], [{a, [2, 3, 4]}])),
    ?assertEqual(
        {[], [{b, [1, 2, 3]}], []},
        diff([{b, [1, 2, 3]}], [])),
    ?assertEqual(
        {[{b, [1, 2, 3]}], [], []},
        diff([], [{b, [1, 2, 3]}])),
    ?assertEqual(
        {[], [], []},
        diff([{a, [1, 2, 3]}], [{a, [1, 2, 3]}])),
    ?assertEqual(
        {[{b, []}], [{c, []}, {a, []}], []},
        diff([{a, []}, {c, []}], [{b, []}])).

diff_backends_test() ->
    Key = {tcp, {11, 136, 231, 163}, 80},
    ?assertEqual(
        {[], [], [{Key, [ {{10, 0, 1, 107}, 15671}], []} ]},
        diff([{Key, [ {{10, 0, 3, 98}, 8895}, {{10, 0, 1, 107}, 16319},
                      {{10, 0, 1, 107}, 3892} ]
             }],
             [{Key, [ {{10, 0, 3, 98}, 8895}, {{10, 0, 1, 107}, 16319},
                      {{10, 0, 1, 107}, 15671}, {{10, 0, 1, 107}, 3892} ]}]) ),
    ?assertEqual(
        {[], [], [{Key, [ {{10, 0, 3, 98}, 12930},
                          {{10, 0, 1, 107}, 18818} ], []}]},
        diff([{Key, [ {{10, 0, 3, 98}, 23520}, {{10, 0, 3, 98}, 1132} ]}],
             [{Key, [ {{10, 0, 3, 98}, 23520}, {{10, 0, 3, 98}, 12930},
                      {{10, 0, 3, 98}, 1132}, {{10, 0, 1, 107}, 18818} ]}]) ).

diff_services_test() ->
    ?assertEqual(
        {[{{tcp, {1, 1, 1, 3}, 80}, [{{10, 0, 0, 3}, 1000}]}], [], []},
        diff([ {{tcp, {1, 1, 1, 1}, 80}, [{{10, 0, 0, 1}, 1000}]},
               {{tcp, {1, 1, 1, 2}, 80}, [{{10, 0, 0, 2}, 1000}]},
               {{tcp, {1, 1, 1, 4}, 80}, [{{10, 0, 0, 4}, 1000}]},
               {{tcp, {1, 1, 1, 5}, 80}, [{{10, 0, 0, 5}, 1000}]} ],
             [ {{tcp, {1, 1, 1, 1}, 80}, [{{10, 0, 0, 1}, 1000}]},
               {{tcp, {1, 1, 1, 2}, 80}, [{{10, 0, 0, 2}, 1000}]},
               {{tcp, {1, 1, 1, 3}, 80}, [{{10, 0, 0, 3}, 1000}]},
               {{tcp, {1, 1, 1, 4}, 80}, [{{10, 0, 0, 4}, 1000}]},
               {{tcp, {1, 1, 1, 5}, 80}, [{{10, 0, 0, 5}, 1000}]} ]) ).

-endif.
