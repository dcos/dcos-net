%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 18. Oct 2016 12:48 AM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_mgr).
-author("sdhillon").

-behaviour(gen_statem).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("gen_netlink/include/netlink.hrl").
-include("dcos_l4lb_lashup.hrl").
-include("dcos_l4lb.hrl").

-define(NOW, 0).
-define(RECONCILE_TIMEOUT, 30000).
-define(SERVER, ?MODULE).

-record(state, {
    last_configured_vips = [],
    last_received_vips = [],
    route_mgr,
    ipvs_mgr,
    route_events_ref,
    kv_ref,
    netns_event_ref,
    ns = [host],
    routes :: ordsets:ordset() | undefined,
    ip_mapping = #{}:: map(),
    tree            :: lashup_gm_route:tree() | undefined
}).

%% API
-export([
    start_link/0,
    push_vips/1,
    push_netns/2,
    local_port_mappings/1
]).

%% gen_statem behaviour
-export([init/1, terminate/3, code_change/4, callback_mode/0]).

%% State callbacks
-export([init/3, notree/3, reconcile/3, maintain/3]).

-ifdef(TEST).
-export([normalize_services_and_dests/1]).
-endif.

push_vips(VIPs0) ->
    VIPs1 = ordsets:from_list(VIPs0),
    gen_statem:cast(?SERVER, {vips, VIPs1}).

push_netns(EventType, EventContent) ->
    gen_statem:cast(?SERVER, {netns_event, self(), EventType, EventContent}).

start_link() ->
    try
        ets:new(local_port_mappings, [public, named_table])
    catch error:badarg ->
        ok
    end,
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

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

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

init([]) ->
    {ok, init, [], {timeout, 0, init}}.

terminate(Reason, State, Data) ->
    lager:warning("Terminating, due to: ~p, in state: ~p, with state data: ~p", [Reason, State, Data]).

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.

callback_mode() ->
    state_functions.

%% TODO: We need to do lashup integration and make it so there are availability checks


%handle_event(EventType, EventContent, StateName, #state{}) ->
%% In the uninitialized state, we want to enumerate the VIPs that exist,
%% and we want to delete the VIPs that aren't in the list
%% Then we we redeliver the event for further processing
%% VIPs are in the structure [{{protocol(), inet:ip_address(), port_num}, [{inet:ip_address(), port_num}]}]
%% [{{tcp,{1,2,3,4},80},[{{33,33,33,2},20320}]}]

init(timeout, init, []) ->
    {ok, KVRef} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({?NODEMETADATA_KEY}) -> true end)),
    {ok, Ref} = lashup_gm_route_events:subscribe(),
    {ok, IPVSMgr} = dcos_l4lb_ipvs_mgr:start_link(),
    {ok, RouteMgr} = dcos_l4lb_route_mgr:start_link(),
    {ok, NetnsRef} = dcos_l4lb_netns_watcher:start_link(),
    State = #state{route_mgr = RouteMgr, ipvs_mgr = IPVSMgr, route_events_ref = Ref,
                   kv_ref = KVRef, netns_event_ref = NetnsRef},
    {next_state, notree, State}.

%% States go notree -> reconcile -> maintain
notree(info, {lashup_gm_route_events, #{ref := Ref, tree := Tree}}, State0 = #state{route_events_ref = Ref}) ->
    State1 = State0#state{tree = Tree},
    {next_state, reconcile, State1};
notree(cast, {netns_event, Ref, EventType, EventContent}, State0 = #state{netns_event_ref = Ref}) ->
    State1 = update_netns(EventType, EventContent, State0),
    {keep_state, State1};
notree(_, _, _) ->
    {keep_state_and_data, postpone}.

reconcile(cast, {vips, VIPs}, State0) ->
    State1 = do_reconcile(VIPs, State0),
    {next_state, maintain, State1};
reconcile(info, {lashup_gm_route_events, #{ref := Ref, tree := Tree}}, State0 = #state{route_events_ref = Ref}) ->
    folsom_metrics:notify({l4lb, events, membership}, {inc, 1}, counter),
    State1 = State0#state{tree = Tree},
    {keep_state, State1};
reconcile(info, {lashup_kv_events, Event = #{ref := Ref}}, State0 = #state{kv_ref = Ref}) ->
    State1 = handle_ip_event(Event, State0),
    {keep_state, State1};
reconcile(cast, {netns_event, Ref, EventType, EventContent}, State0 = #state{netns_event_ref = Ref}) ->
    State1 = update_netns(EventType, EventContent, State0),
    {keep_state, State1}.

maintain(cast, {vips, VIPs}, State0) ->
    State1 = maintain(VIPs, State0),
    {keep_state, State1, {timeout, ?RECONCILE_TIMEOUT, do_reconcile}};
maintain(internal, maintain, State0 = #state{last_received_vips = VIPs}) ->
    State1 = maintain(VIPs, State0),
    {keep_state, State1, {timeout, ?RECONCILE_TIMEOUT, do_reconcile}};
maintain(info, {lashup_gm_route_events, #{ref := Ref, tree := Tree}}, State0 = #state{route_events_ref = Ref}) ->
    State1 = State0#state{tree = Tree},
    {keep_state, State1, {next_event, internal, maintain}};
maintain(info, {lashup_kv_events, Event = #{ref := Ref}}, State0 = #state{kv_ref = Ref}) ->
    State1 = handle_ip_event(Event, State0),
    {keep_state, State1, {timeout, ?RECONCILE_TIMEOUT, do_reconcile}};
maintain(cast, {netns_event, Ref, reconcile_netns, EventContent},
         State0 = #state{netns_event_ref = Ref}) ->
    State1 = update_netns(reconcile_netns, EventContent, State0),
    {keep_state, State1, {timeout, ?NOW, do_reconcile}};
maintain(cast, {netns_event, Ref, EventType, EventContent}, State0 = #state{netns_event_ref = Ref}) ->
    State1 = update_netns(EventType, EventContent, State0),
    {keep_state, State1, {timeout, ?RECONCILE_TIMEOUT, do_reconcile}};
 maintain(timeout, do_reconcile, State0 = #state{last_received_vips = VIPs}) ->
    State1 = do_reconcile(VIPs, State0),
    {keep_state, State1, {timeout, ?RECONCILE_TIMEOUT, do_reconcile}}.

handle_ip_event(_Event = #{value := Value}, State0) ->
    IPToNodeName = [{IP, NodeName} || {?LWW_REG(IP), NodeName} <- Value],
    IPMapping = maps:from_list(IPToNodeName),
    State0#state{ip_mapping = IPMapping}.

update_netns(add_netns, UpdateValue, State = #state{
        ns = Namespaces0, ipvs_mgr = IPVSMgr, route_mgr = RouteMgr}) ->
    Namespaces1 = dcos_l4lb_route_mgr:add_netns(RouteMgr, UpdateValue),
    Namespaces1 = dcos_l4lb_ipvs_mgr:add_netns(IPVSMgr, UpdateValue),
    lists:foreach(fun(Ns) -> push_config(Ns, State) end, Namespaces1),
    Namespaces2 = ordsets:union(ordsets:from_list(Namespaces1), Namespaces0),
    State#state{ns = Namespaces2};
update_netns(remove_netns, UpdateValue, State = #state{
        ns = Namespaces0, ipvs_mgr = IPVSMgr, route_mgr = RouteMgr}) ->
    Namespaces1 = dcos_l4lb_route_mgr:remove_netns(RouteMgr, UpdateValue),
    Namespaces1 = dcos_l4lb_route_mgr:remove_netns(IPVSMgr, UpdateValue),
    Namespaces2 = ordsets:subtract(Namespaces0, ordsets:from_list(Namespaces1)),
    State#state{ns = Namespaces2};
update_netns(reconcile_netns, UpdateValue, State = #state{
        ns = Namespaces0, ipvs_mgr = IPVSMgr, route_mgr = RouteMgr}) ->
    Namespaces1 = dcos_l4lb_route_mgr:add_netns(RouteMgr, UpdateValue),
    Namespaces1 = dcos_l4lb_ipvs_mgr:add_netns(IPVSMgr, UpdateValue),
    Namespaces2 = ordsets:union(ordsets:from_list(Namespaces1), Namespaces0),
    State#state{ns = Namespaces2}.

push_config(Namespace, State) ->
    push_routes(Namespace, State),
    push_services(Namespace, State).

push_routes(Namespace, #state{routes = Routes, route_mgr = RouteMgr}) ->
    dcos_l4lb_route_mgr:add_routes(RouteMgr, Routes, Namespace).

push_services(Namespace, State = #state{last_configured_vips = VIPs}) ->
    lists:foreach(fun({VIP, BEs}) -> add_service(VIP, BEs, Namespace, State) end, VIPs).

do_reconcile(VIPs, State0 = #state{ns = Namespaces}) ->
    folsom_metrics:notify({l4lb, vips}, length(VIPs), gauge),
    VIPs0 = vips_port_mappings(VIPs),
    VIPs1 = process_reachability(VIPs0, State0),
    Routes = ordsets:from_list([VIP || {{_Proto, VIP, _Port}, _Backends} <- VIPs1]),
    State1 = State0#state{last_received_vips = VIPs0, last_configured_vips = VIPs1, routes = Routes},
    lists:foreach(fun(Ns) ->
                     do_reconcile_routes(Ns, State1),
                     do_reconcile_services(Ns, State1)
                  end, Namespaces),
    State1.

do_reconcile_routes(Namespace, State = #state{routes = Routes}) ->
    InstalledRoutes = installed_routes(Namespace, State),
    do_update_routes(Routes, InstalledRoutes, Namespace, State).

installed_routes(Namespace, #state{route_mgr = RouteMgr}) ->
    dcos_l4lb_route_mgr:get_routes(RouteMgr, Namespace).

do_update_routes(NewRoutes, OldRoutes, Namespace, #state{route_mgr = RouteMgr}) ->
    RoutesToAdd = ordsets:subtract(NewRoutes, OldRoutes),
    RoutesToDel = ordsets:subtract(OldRoutes, NewRoutes),
    dcos_l4lb_route_mgr:add_routes(RouteMgr, RoutesToAdd, Namespace),
    dcos_l4lb_route_mgr:remove_routes(RouteMgr, RoutesToDel, Namespace).

do_reconcile_services(Namespace, State = #state{last_configured_vips = VIPs1}) ->
    InstalledState = installed_state(Namespace, State),
    VIPs2 = lists:map(fun do_transform/1, VIPs1),
    Diff = generate_diff(InstalledState, VIPs2),
    apply_diff(Diff, Namespace, State).

do_transform({VIP, BEs}) ->
    {VIP, [BE || {_AgentIP, BE} <- BEs]}.

installed_state(Namespace, #state{ipvs_mgr = IPVSMgr}) ->
    Services = dcos_l4lb_ipvs_mgr:get_services(IPVSMgr, Namespace),
    ServicesAndDests0 = [{Service, dcos_l4lb_ipvs_mgr:get_dests(IPVSMgr, Service, Namespace)} || Service <- Services],
    ServicesAndDests1 = lists:map(fun normalize_services_and_dests/1, ServicesAndDests0),
    lists:usort(ServicesAndDests1).

%% Converts IPVS service / dests into our normal dcos_l4lb ones
normalize_services_and_dests({Service0, Destinations0}) ->
    {AddressFamily, Service1} = dcos_l4lb_ipvs_mgr:service_address(Service0),
    Destinations1 = lists:map(
                      fun(Dest) ->
                          dcos_l4lb_ipvs_mgr:destination_address(AddressFamily, Dest)
                      end, Destinations0),
    Destinations2 = lists:usort(Destinations1),
    {Service1, Destinations2}.

apply_diff({ServicesToAdd, ServicesToRemove, ServicesToModify}, Namespace, State) ->
    lists:foreach(fun({VIP, _BEs}) -> remove_service(VIP, Namespace, State) end, ServicesToRemove),
    lists:foreach(fun({VIP, BEs}) -> add_service(VIP, BEs, Namespace, State) end, ServicesToAdd),
    lists:foreach(fun({VIP, BEAdd, BERemove}) ->
        modify_service(VIP, BEAdd, BERemove, Namespace, State)
    end, ServicesToModify).

modify_service({Protocol, IP, Port}, BEAdd, BERemove, Namespace, #state{ipvs_mgr = IPVSMgr}) ->
    lists:foreach(fun
        ({_AgentIP, {BEIP, BEPort}}) ->
            dcos_l4lb_ipvs_mgr:add_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol, Namespace);
        ({BEIP, BEPort}) ->
            dcos_l4lb_ipvs_mgr:add_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol, Namespace)
        end,
        BEAdd),
    lists:foreach(fun
        ({_AgentIP, {BEIP, BEPort}}) ->
            dcos_l4lb_ipvs_mgr:remove_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol, Namespace);
        ({BEIP, BEPort}) ->
            dcos_l4lb_ipvs_mgr:remove_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol, Namespace)
        end,
        BERemove).

remove_service({Protocol, IP, Port}, Namespace, #state{ipvs_mgr = IPVSMgr}) ->
    dcos_l4lb_ipvs_mgr:remove_service(IPVSMgr, IP, Port, Protocol, Namespace).

add_service({Protocol, IP, Port}, BEs, Namespace, #state{ipvs_mgr = IPVSMgr}) ->
    dcos_l4lb_ipvs_mgr:add_service(IPVSMgr, IP, Port, Protocol, Namespace),
    lists:foreach(fun
      ({_AgentIP, {BEIP, BEPort}}) ->
          dcos_l4lb_ipvs_mgr:add_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol, Namespace);
      ({BEIP, BEPort}) ->
          dcos_l4lb_ipvs_mgr:add_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol, Namespace)
      end,
      BEs).

process_reachability(VIPs, State) ->
    {VIPs0, RCount, UCount} =
        lists:foldl(fun({VIP, BEs}, {Acc, RCount, UCount}) ->
            {BEs0, RC, UC} = reachable_backends(BEs, State),
            {[{VIP, BEs0} | Acc], RCount + RC, UCount + UC}
        end, {[], 0, 0}, VIPs),
    folsom_metrics:notify({l4lb, backends, reachable}, RCount, gauge),
    folsom_metrics:notify({l4lb, backends, unreachable}, UCount, gauge),
    VIPs0.

maintain(VIPs, State = #state{ns = Namespaces, routes = Routes, last_configured_vips = LastConfigured}) ->
    VIPs0 = vips_port_mappings(VIPs),
    VIPs1 = process_reachability(VIPs0, State),
    Diff = generate_diff(LastConfigured, VIPs1),
    NewRoutes = ordsets:from_list([VIP || {{_Proto, VIP, _Port}, _Backends} <- VIPs1]),
    lager:debug("Last Configured: ~p, VIPs: ~p, NewRoutes ~p, Diff ~p", [LastConfigured, VIPs1, NewRoutes, Diff]),
    lists:foreach(fun(Namespace) ->
                    do_update_routes(NewRoutes, Routes, Namespace, State),
                    apply_diff(Diff, Namespace, State)
                  end, Namespaces),
    State#state{last_configured_vips = VIPs1, last_received_vips = VIPs0, routes = NewRoutes}.

%% Returns {VIPsToRemove, VIPsToAdd, [VIP, BackendsToRemove, BackendsToAdd]}
generate_diff(Lhs, Rhs) ->
    generate_diff(Lhs, Rhs, [], [], []).

%% The VIPs are equal AND the backends are equal. Ignore it.
generate_diff([{VIP, BE}|RestLhs], [{VIP, BE}|RestRhs], VIPsToAdd, VIPsToRemove, Mutations) ->
    generate_diff(RestLhs, RestRhs, VIPsToAdd, VIPsToRemove, Mutations);
%% VIPs are equal, but the backends are different, prepare a mutation entry
generate_diff([{VIP, BELhs}|RestLhs], [{VIP, BERhs}|RestRhs], VIPsToAdd, VIPsToRemove, Mutations0) ->
    BERhs1 = ordsets:from_list(BERhs),
    BELhs1 = ordsets:from_list(BELhs),
    BEToAdd = ordsets:subtract(BERhs1, BELhs1),
    BEToRemove = ordsets:subtract(BELhs1, BERhs1),
    Mutation = {VIP, BEToAdd, BEToRemove},
    generate_diff(RestLhs, RestRhs, VIPsToAdd, VIPsToRemove, [Mutation|Mutations0]);
%% New VIP
generate_diff(Lhs = [VIPLhs|_RestLhs], [VIPRhs|RestRhs], VIPsToAdd0, VIPsToRemove, Mutations) when VIPRhs > VIPLhs ->
    generate_diff(Lhs, RestRhs, [VIPRhs|VIPsToAdd0], VIPsToRemove, Mutations);
%% To delete VIP
generate_diff([VIPLhs|RestLhs], Rhs = [VIPRhs|_RestRhs], VIPsToAdd, VIPsToRemove0, Mutations) when VIPRhs < VIPLhs ->
    generate_diff(RestLhs, Rhs, VIPsToAdd, [VIPLhs|VIPsToRemove0], Mutations);
generate_diff([], [], VIPsToAdd, VIPsToRemove, Mutations) ->
    {VIPsToAdd, VIPsToRemove, Mutations};
generate_diff([], Rhs, VIPsToAdd0, VIPsToRemove, Mutations) ->
    {VIPsToAdd0 ++ Rhs, VIPsToRemove, Mutations};
generate_diff(Lhs, [], VIPsToAdd, VIPsToRemove0, Mutations) ->
    {VIPsToAdd, VIPsToRemove0 ++ Lhs, Mutations}.

reachable_backends(Backends, State) ->
    reachable_backends(Backends, [], [], State).

reachable_backends([], _OpenBackends = [], ClosedBackends, _State) ->
    {ClosedBackends, 0, length(ClosedBackends)};
reachable_backends([], OpenBackends, ClosedBackends, _State) ->
    {OpenBackends, length(OpenBackends), length(ClosedBackends)};
reachable_backends([BE = {IP, {_BEIP, _BEPort}}|Rest], OB, CB, State = #state{ip_mapping = IPMapping, tree = Tree}) ->
    case IPMapping of
        #{IP := NodeName} ->
            case lashup_gm_route:distance(NodeName, Tree) of
                infinity ->
                    reachable_backends(Rest, OB, [BE|CB], State);
                _ ->
                    reachable_backends(Rest, [BE|OB], CB, State)
            end;
        _ ->
            reachable_backends(Rest, OB, [BE|CB], State)
    end.


vips_port_mappings(VIPs) ->
    PMs = local_port_mappings(),
    AgentIP = dcos_net_dist:nodeip(),
    % remove port mappings for local backends
    lists:map(fun ({{Protocol, VIP, VIPPort}, BEs}) ->
        BEs0 = bes_port_mappings(PMs, Protocol, AgentIP, BEs),
        {{Protocol, VIP, VIPPort}, BEs0}
    end, VIPs).

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

generate_diffs_test() ->
    ?assertEqual({[], [], []}, generate_diff([], [])),
    ?assertEqual({[], [], [{a, [4], [1]}]}, generate_diff([{a, [1, 2, 3]}], [{a, [2, 3, 4]}])),
    ?assertEqual({[], [{b, [1, 2, 3]}], []}, generate_diff([{b, [1, 2, 3]}], [])),
    ?assertEqual({[{b, [1, 2, 3]}], [], []}, generate_diff([], [{b, [1, 2, 3]}])),
    ?assertEqual({[], [], []}, generate_diff([{a, [1, 2, 3]}], [{a, [1, 2, 3]}])),
    ?assertEqual({[{b, []}], [{a, []}, {c, []}], []}, generate_diff([{a, []}, {c, []}], [{b, []}])),
    Diff1 =
        generate_diff(
            [
                {
                    {tcp, {11, 136, 231, 163}, 80},
                    [
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 8895}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 16319}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 3892}}
                    ]
                }
            ],
            [
                {{tcp, {11, 136, 231, 163}, 80},
                    [
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 8895}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 16319}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 15671}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 3892}}
                    ]
                }
            ]),
    ?assertEqual(
        {[], [], [{{tcp, {11, 136, 231, 163}, 80}, [{{10, 0, 1, 107}, {{10, 0, 1, 107}, 15671}}], []}]}, Diff1),
    Diff2 =
        generate_diff(
            [
                {
                    {tcp, {11, 136, 231, 163}, 80},
                    [
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 23520}},
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 1132}}
                    ]
                }
            ],
            [
                {
                    {tcp, {11, 136, 231, 163}, 80},
                    [
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 23520}},
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 12930}},
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 1132}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 18818}}
                    ]
                }
            ]),
    ?assertEqual(
        {[], [], [{{tcp, {11, 136, 231, 163}, 80},
                     [{{10, 0, 1, 107}, {{10, 0, 1, 107}, 18818}},
                      {{10, 0, 3, 98}, {{10, 0, 3, 98}, 12930}}],
         []}]}, Diff2).
-endif.
