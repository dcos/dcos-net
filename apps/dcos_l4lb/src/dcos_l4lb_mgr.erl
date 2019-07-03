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
    local_port_mappings/1,
    init_metrics/0
]).

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_continue/2,
    handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    % pids and refs
    ipvs_mgr :: pid(),
    route_mgr :: pid(),
    ipset_mgr :: pid(),
    netns_mgr :: pid(),
    route_ref :: reference(),
    nodes_ref :: reference(),
    recon_ref :: reference(),
    % data
    tree = #{} :: lashup_gm_route:tree(),
    nodes = #{} :: #{inet:ip4_address() => node()},
    namespaces = [host] :: [namespace()],
    % vips
    vips = [] :: [{key(), [backend()]}],
    prev_vips = [] :: [{key(), [ipport()]}]
}).
-type state() :: #state{}.

-type key() :: dcos_l4lb_mesos_poller:key().
-type backend() :: dcos_l4lb_mesos_poller:backend().
-type ipport() :: {inet:ip_address(), inet:port_number()}.
-type namespace() :: term().

-define(GM_EVENTS(R, T), {lashup_gm_route_events, #{ref := R, tree := T}}).


-spec(push_vips(VIPs :: [{Key, [Backend]}]) -> ok
    when Key :: dcos_l4lb_mesos_poller:key(),
         Backend :: dcos_l4lb_mesos_poller:backend()).
push_vips(VIPs) ->
    Begin = erlang:monotonic_time(),
    try
        gen_server:call(?MODULE, {vips, VIPs})
    catch exit:{noproc, _MFA} ->
        ok
    after
        End = erlang:monotonic_time(),
        update_summary(vips_duration_seconds, End - Begin)
    end.

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
    {ok, {}, {continue, {}}}.

handle_continue({}, {}) ->
    {noreply, handle_init()}.

handle_call({vips, VIPs}, _From, State) ->
    {reply, ok, handle_vips(VIPs, State)};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({netns, Event}, State) ->
    {noreply, handle_netns_event(Event, State)};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(?GM_EVENTS(_R, _T)=Event, State) ->
    {noreply, handle_gm_event(Event, State)};
handle_info({lashup_kv_event, Ref, Key}, State) ->
    {noreply, handle_kv_event(Ref, Key, State)};
handle_info({timeout, _Ref, reconcile}, State) ->
    State0 = handle_reconcile(State),
    State1 = handle_gc(State0),
    {noreply, State1, hibernate};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Events functions
%%%===================================================================

-define(SKIP(Pattern, Value, Init), (fun Skip(X) ->
    % Skip message if there is yet another such message in
    % the message queue. It should improve the convergence.
    receive
        Pattern ->
            Skip(Value)
    after 0 ->
        X
    end
end)(Init)).

-spec(handle_init() -> state()).
handle_init() ->
    {ok, IPVSMgr} = dcos_l4lb_ipvs_mgr:start_link(),
    {ok, RouteMgr} = dcos_l4lb_route_mgr:start_link(),
    {ok, IPSetMgr} = dcos_l4lb_ipset_mgr:start_link(),
    {ok, NetNSMgr} = dcos_l4lb_netns_watcher:start_link(),

    MatchSpec = ets:fun2ms(fun ({?NODEMETADATA_KEY}) -> true end),
    {ok, NodesRef} = lashup_kv:subscribe(MatchSpec),
    {ok, RouteRef} = lashup_gm_route_events:subscribe(),
    ReconRef = start_reconcile_timer(),

    #state{ipvs_mgr=IPVSMgr, route_mgr=RouteMgr,
           ipset_mgr=IPSetMgr, netns_mgr=NetNSMgr,
           route_ref=RouteRef, nodes_ref=NodesRef,
           recon_ref=ReconRef}.

-spec(handle_gm_event(?GM_EVENTS(Ref, Tree), state()) -> state()
    when Ref :: reference(), Tree :: lashup_gm_route:tree()).
handle_gm_event(?GM_EVENTS(Ref, Tree), #state{route_ref=Ref}=State) ->
    Tree0 = ?SKIP(?GM_EVENTS(Ref, T), T, Tree),
    State#state{tree=Tree0};
handle_gm_event(_Event, State) ->
    State.

-spec(handle_kv_event(Ref, Key, state()) -> state()
    when Ref :: reference(), Key :: term()).
handle_kv_event(Ref, Key, #state{nodes_ref=Ref}=State) ->
    ok = lashup_kv:flush(Ref, Key),
    Value = lashup_kv:value(Key),
    Nodes = [{IP, Node} || {?LWW_REG(IP), Node} <- Value],
    State#state{nodes=maps:from_list(Nodes)};
handle_kv_event(_Ref, _Key, State) ->
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

-spec(handle_reconcile(state()) -> state()).
handle_reconcile(#state{vips=VIPs, recon_ref=Ref}=State) ->
    erlang:cancel_timer(Ref),
    Begin = erlang:monotonic_time(),
    try handle_reconcile(VIPs, State) of
        State0 ->
            Ref0 = start_reconcile_timer(),
            State0#state{recon_ref=Ref0}
    after
        End = erlang:monotonic_time(),
        update_summary(vips_duration_seconds, End - Begin)
    end.

-spec(start_reconcile_timer() -> reference()).
start_reconcile_timer() ->
    Timeout = application:get_env(dcos_l4lb, reconcile_timeout, 30000),
    erlang:start_timer(Timeout, self(), reconcile).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(handle_reconcile([{key(), [backend()]}], state()) -> state()).
handle_reconcile(VIPs, #state{tree=Tree, nodes=Nodes, namespaces=Namespaces,
        route_mgr=RouteMgr, ipvs_mgr=IPVSMgr, ipset_mgr=IPSetMgr}=State) ->
    % If everything is ok this function is silent and changes nothing.
    VIPs0 = vips_port_mappings(VIPs),
    VIPs1 = healthy_vips(VIPs0, Nodes, Tree),
    VIPsP = prepare_vips(VIPs1),
    Routes = get_vip_routes(VIPs),
    Diffs =
        lists:map(fun (Namespace) ->
            NamespaceBin = namespace2bin(Namespace),
            LogPrefix = <<"netns: ", NamespaceBin/binary, "; ">>,

            PrevRoutes = get_routes(RouteMgr, Namespace),
            DiffRoutes = dcos_net_utils:complement(Routes, PrevRoutes),

            PrevVIPsP = get_vips(IPVSMgr, Namespace),
            DiffVIPs = diff(PrevVIPsP, VIPsP),

            {Namespace, LogPrefix, DiffRoutes, DiffVIPs}
        end, Namespaces),

    Keys = get_vip_keys(VIPs1),
    PrevKeys = get_ipset_entries(IPSetMgr),
    DiffKeys = dcos_net_utils:complement(Keys, PrevKeys),

    State0 = handle_reconcile_apply(Diffs, DiffKeys, State),

    State0#state{prev_vips=VIPs1}.

-spec(handle_reconcile_apply([Diff], diff_keys(), state()) -> state()
    when Diff :: {namespace(), binary(), diff_vips(), diff_routes()}).
handle_reconcile_apply(
        Diffs, {KeysToAdd, KeysToDel},
        #state{route_mgr=RouteMgr, ipvs_mgr=IPVSMgr,
               ipset_mgr=IPSetMgr}=State) ->
    lists:foreach(fun ({Namespace, LogPrefix, {_, RoutesToDel}, _DiffVIPs}) ->
        ok = remove_routes(RouteMgr, RoutesToDel, Namespace),
        ok = log_routes_diff(LogPrefix, {[], RoutesToDel}),
        update_counter(reconciled_routes_total, length(RoutesToDel))
    end, Diffs),

    add_ipset_entries(IPSetMgr, KeysToAdd),
    log_ipset_diff({KeysToAdd, []}),
    update_counter(reconciled_ipset_entries_total, length(KeysToAdd)),

    lists:foreach(fun ({Namespace, LogPrefix, _DiffRoutes, DiffVIPs}) ->
        ok = apply_vips_diff(IPVSMgr, Namespace, DiffVIPs),
        ok = log_vips_diff(LogPrefix, DiffVIPs),
        update_counter(reconciled_ipvs_rules_total, vip_diff_size(DiffVIPs))
    end, Diffs),

    remove_ipset_entries(IPSetMgr, KeysToDel),
    log_ipset_diff({[], KeysToDel}),
    update_counter(reconciled_ipset_entries_total, length(KeysToDel)),

    lists:foreach(fun ({Namespace, LogPrefix, {RoutesToAdd, _}, _DiffVIPs}) ->
        ok = add_routes(RouteMgr, RoutesToAdd, Namespace),
        ok = log_routes_diff(LogPrefix, {RoutesToAdd, []}),
        update_counter(reconciled_routes_total, length(RoutesToAdd))
    end, Diffs),
    State.

-spec(handle_vips([{key(), [backend()]}], state()) -> state()).
handle_vips(VIPs, #state{tree=Tree, nodes=Nodes, prev_vips=PrevVIPs}=State) ->
    VIPs0 = vips_port_mappings(VIPs),
    VIPs1 = healthy_vips(VIPs0, Nodes, Tree),
    DiffVIPs = diff(prepare_vips(PrevVIPs), prepare_vips(VIPs1)),

    Routes = get_vip_routes(VIPs1),
    PrevRoutes = get_vip_routes(PrevVIPs),
    DiffRoutes = dcos_net_utils:complement(Routes, PrevRoutes),

    Keys = get_vip_keys(VIPs1),
    PrevKeys = get_vip_keys(PrevVIPs),
    DiffKeys = dcos_net_utils:complement(Keys, PrevKeys),

    State0 = handle_vips_apply(DiffVIPs, DiffRoutes, DiffKeys, State),

    update_gauge(vips, length(VIPs)),
    State0#state{vips=VIPs, prev_vips=VIPs1}.

-spec(handle_vips_apply(DiffVIPs, DiffRoutes, DiffKeys, State) -> State
    when DiffVIPs :: diff_vips(), DiffRoutes :: diff_routes(),
         DiffKeys :: diff_keys(), State :: state()).
handle_vips_apply(
        DiffVIPs, {RoutesToAdd, RoutesToDel}, {KeysToAdd, KeysToDel},
        #state{namespaces=Namespaces, route_mgr=RouteMgr,
               ipvs_mgr=IPVSMgr, ipset_mgr=IPSetMgr}=State) ->
    lists:foreach(fun (Namespace) ->
        ok = remove_routes(RouteMgr, RoutesToDel, Namespace)
    end, Namespaces),
    ok = log_routes_diff({[], RoutesToDel}),

    add_ipset_entries(IPSetMgr, KeysToAdd),
    log_ipset_diff({KeysToAdd, []}),

    lists:foreach(fun (Namespace) ->
        ok = apply_vips_diff(IPVSMgr, Namespace, DiffVIPs)
    end, Namespaces),
    ok = log_vips_diff(DiffVIPs),

    remove_ipset_entries(IPSetMgr, KeysToDel),
    log_ipset_diff({[], KeysToDel}),

    lists:foreach(fun (Namespace) ->
        ok = add_routes(RouteMgr, RoutesToAdd, Namespace)
    end, Namespaces),
    ok = log_routes_diff({RoutesToAdd, []}),

    State.

%%%===================================================================
%%% Routes functions
%%%===================================================================

-type diff_routes() :: {[inet:ip_address()], [inet:ip_address()]}.

-spec(get_routes(pid(), namespace()) -> [inet:ip_address()]).
get_routes(RouteMgr, Namespace) ->
    dcos_l4lb_route_mgr:get_routes(RouteMgr, Namespace).

-spec(get_vip_routes(VIPs :: [{key(), [backend()]}]) -> [inet:ip_address()]).
get_vip_routes(VIPs) ->
    lists:usort([IP || {{_Proto, IP, _Port}, _Backends} <- VIPs]).

-spec(add_routes(pid(), [inet:ip_address()], namespace()) -> ok).
add_routes(RouteMgr, Routes, Namespace) ->
    dcos_l4lb_route_mgr:add_routes(RouteMgr, Routes, Namespace).

-spec(remove_routes(pid(), [inet:ip_address()], namespace()) -> ok).
remove_routes(RouteMgr, Routes, Namespace) ->
    dcos_l4lb_route_mgr:remove_routes(RouteMgr, Routes, Namespace).

%%%===================================================================
%%% IPSet functions
%%%===================================================================

-type diff_keys() :: {[key()], [key()]}.

-spec(get_vip_keys(VIPs :: [{key(), [backend()]}]) -> [key()]).
get_vip_keys(VIPs) ->
    [ VIPKey || {VIPKey, _Backends} <- VIPs].

-spec(get_ipset_entries(pid()) -> [key()]).
get_ipset_entries(IPSetMgr) ->
    dcos_l4lb_ipset_mgr:get_entries(IPSetMgr).

-spec(add_ipset_entries(pid(), [key()]) -> ok).
add_ipset_entries(IPSetMgr, KeysToAdd) ->
    dcos_l4lb_ipset_mgr:add_entries(IPSetMgr, KeysToAdd).

-spec(remove_ipset_entries(pid(), [key()]) -> ok).
remove_ipset_entries(IPSetMgr, KeysToDel) ->
    dcos_l4lb_ipset_mgr:remove_entries(IPSetMgr, KeysToDel).

%%%===================================================================
%%% IPVS functions
%%%===================================================================

-spec(prepare_vips([{key(), [backend()]}]) -> [{key(), [ipport()]}]).
prepare_vips(VIPs) ->
    lists:map(fun ({VIP, BEs}) ->
        {VIP, [BE || {_AgentIP, BE} <- BEs]}
    end, VIPs).

-spec(get_vips(pid(), namespace()) -> [{key(), [ipport()]}]).
get_vips(IPVSMgr, Namespace) ->
    Services = get_vip_services(IPVSMgr, Namespace),
    lists:map(fun (S) -> get_vip(IPVSMgr, Namespace, S) end, Services).

-spec(get_vip_services(pid(), namespace()) -> [Service]
    when Service :: dcos_l4lb_ipvs_mgr:service()).
get_vip_services(IPVSMgr, Namespace) ->
    Services = dcos_l4lb_ipvs_mgr:get_services(IPVSMgr, Namespace),
    FVIPs = lists:map(fun dcos_l4lb_ipvs_mgr:service_address/1, Services),
    maps:values(maps:from_list(lists:zip(FVIPs, Services))).

-spec(get_vip(pid(), namespace(), Service) -> {key(), [ipport()]}
    when Service :: dcos_l4lb_ipvs_mgr:service()).
get_vip(IPVSMgr, Namespace, Service) ->
    {Family, VIP} = dcos_l4lb_ipvs_mgr:service_address(Service),
    Dests = dcos_l4lb_ipvs_mgr:get_dests(IPVSMgr, Service, Namespace),
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

-spec(apply_vips_diff(pid(), namespace(), diff_vips()) -> ok).
apply_vips_diff(IPVSMgr, Namespace, {ToAdd, ToDel, ToMod}) ->
    lists:foreach(fun (VIP) ->
        vip_del(IPVSMgr, Namespace, VIP)
    end, ToDel),
    lists:foreach(fun (VIP) ->
        vip_add(IPVSMgr, Namespace, VIP)
    end, ToAdd),
    lists:foreach(fun (VIP) ->
        vip_mod(IPVSMgr, Namespace, VIP)
    end, ToMod).

-spec(vip_add(pid(), namespace(), {key(), [ipport()]}) -> ok).
vip_add(IPVSMgr, Namespace, {{Protocol, IP, Port}, BEs}) ->
    dcos_l4lb_ipvs_mgr:add_service(IPVSMgr, IP, Port, Protocol, Namespace),
    lists:foreach(fun ({BEIP, BEPort}) ->
        dcos_l4lb_ipvs_mgr:add_dest(
            IPVSMgr, IP, Port,
            BEIP, BEPort,
            Protocol, Namespace)
    end, BEs).

-spec(vip_del(pid(), namespace(), {key(), [ipport()]}) -> ok).
vip_del(IPVSMgr, Namespace, {{Protocol, IP, Port}, _BEs}) ->
    dcos_l4lb_ipvs_mgr:remove_service(IPVSMgr, IP, Port, Protocol, Namespace).

-spec(vip_mod(pid(), namespace(), {key(), [ipport()], [ipport()]}) -> ok).
vip_mod(IPVSMgr, Namespace, {{Protocol, IP, Port}, ToAdd, ToDel}) ->
    lists:foreach(fun ({BEIP, BEPort}) ->
        dcos_l4lb_ipvs_mgr:add_dest(
            IPVSMgr, IP, Port,
            BEIP, BEPort,
            Protocol, Namespace)
    end, ToAdd),
    lists:foreach(fun ({BEIP, BEPort}) ->
        dcos_l4lb_ipvs_mgr:remove_dest(
            IPVSMgr, IP, Port,
            BEIP, BEPort,
            Protocol, Namespace)
    end, ToDel).

-spec(vip_diff_size(diff_vips()) -> non_neg_integer()).
vip_diff_size({ToAdd, ToDel, ToMod}) ->
    ToAddSize = lists:sum([length(V) || {_K, V} <- ToAdd]),
    ToDelSize = lists:sum([length(V) || {_K, V} <- ToDel]),
    ToModSize = lists:sum([length(A) + length(B) || {_K, A, B} <- ToMod]),
    ToAddSize + ToDelSize + ToModSize.

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
diff([{Key, Va}|ListA], [{Key, Vb}|ListB], Acc, Bcc, Mcc) ->
    case dcos_net_utils:complement(Vb, Va) of
        {[], []} ->
            diff(ListA, ListB, Acc, Bcc, Mcc);
        {Ma, Mb} ->
            diff(ListA, ListB, Acc, Bcc, [{Key, Ma, Mb}|Mcc])
    end;
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

    Result =
        lists:map(fun ({VIP, BEs}) ->
            {Healthy, BEs0} = healthy_backends(BEs, Agents),
            {{VIP, BEs0}, {length(BEs), Healthy}}
        end, VIPs),
    {VIPs0, Stat} = lists:unzip(Result),

    % Stat :: [{AllBackends, HealthyBackends}]
    update_gauge(backends, lists:sum([B || {B, _H} <- Stat])),
    update_gauge(unreachable_backends, lists:sum([B - H || {B, H} <- Stat])),
    update_gauge(unreachable_vips, length([B || {B, 0} <- Stat, B =/= 0])),

    VIPs0.

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
    Unreachable = [IP || {IP, false} <- Result],
    [ lager:warning(
        "L4LB unreachable agent nodes, size: ~p, ~p",
        [length(Unreachable), Unreachable])
    || Unreachable =/= [] ],
    update_gauge(unreachable_nodes, length(Unreachable)),
    maps:from_list(Result).

-spec(healthy_backends([backend()], Agents) -> {non_neg_integer(), [backend()]}
    when Agents :: #{inet:ip4_address() => boolean()}).
healthy_backends(BEs, Agents) ->
    case [BE || BE={IP, _BE} <- BEs, maps:get(IP, Agents)] of
        [] -> {0, BEs};
        BEs0 -> {length(BEs0), BEs0}
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
%%% Logging functions
%%%===================================================================

-spec(namespace2bin(term()) -> binary()).
namespace2bin(host) ->
    <<"host">>;
namespace2bin(Namespace) ->
    String =
        try
            io_lib:format("~s", [Namespace])
        catch error:badarg ->
            io_lib:format("~p", [Namespace])
        end,
    iolist_to_binary(String).

-spec(log_vips_diff(diff_vips()) -> ok).
log_vips_diff(Diff) ->
    log_vips_diff(<<>>, Diff).

-spec(log_vips_diff(binary(), diff_vips()) -> ok).
log_vips_diff(Prefix, {ToAdd, ToDel, ToMod}) ->
    lists:foreach(fun ({{Proto, VIP, Port}, Backends}) ->
        lager:notice(
            "~sVIP service was added: ~p://~s:~p, Backends: ~p",
            [Prefix, Proto, inet:ntoa(VIP), Port, Backends])
    end, ToAdd),
    lists:foreach(fun ({{Proto, VIP, Port}, _BEs}) ->
        lager:notice(
            "~sVIP service was deleted: ~p://~s:~p",
            [Prefix, Proto, inet:ntoa(VIP), Port])
    end, ToDel),
    lists:foreach(fun ({{Proto, VIP, Port}, Added, Removed}) ->
        lager:notice(
            "~sVIP service was modified: ~p://~s:~p, Backends: +~p -~p",
            [Prefix, Proto, inet:ntoa(VIP), Port, Added, Removed])
    end, ToMod).

-spec(log_routes_diff(diff_routes()) -> ok).
log_routes_diff(Diff) ->
    log_routes_diff(<<>>, Diff).

-spec(log_routes_diff(binary(), diff_routes()) -> ok).
log_routes_diff(Prefix, {ToAdd, ToDel}) ->
    [ lager:notice(
        "~sVIP routes were added, routes: ~p, IPs: ~p",
        [Prefix, length(ToAdd), ToAdd]) || ToAdd =/= [] ],
    [ lager:notice(
        "~sVIP routes were removed, routes: ~p, IPs: ~p",
        [Prefix, length(ToDel), ToDel]) || ToDel =/= [] ],
    ok.

-spec(log_ipset_diff(diff_keys()) -> ok).
log_ipset_diff({ToAdd, ToDel}) ->
    IPSetEnabled = dcos_l4lb_config:ipset_enabled(),
    [ lager:notice(
        "VIPs were added to ipset: ~p",
        [ToAdd]) || ToAdd =/= [], IPSetEnabled ],
    [ lager:notice(
        "VIPs were removed from ipset: ~p",
        [ToDel]) || ToDel =/= [], IPSetEnabled ],
    ok.

-spec(log_netns_diff(Namespaces, Namespaces) -> ok
    when Namespaces :: term()).
log_netns_diff(Namespaces, Namespaces) ->
    ok;
log_netns_diff(Namespaces, _PrevNamespaces) ->
    <<", ", Str/binary>> =
        << <<", ", (namespace2bin(Namespace))/binary>>
        || Namespace <- Namespaces>>,
    lager:notice("L4LB network namespaces: ~s", [Str]).

%%%===================================================================
%%% Network Namespace functions
%%%===================================================================

-spec(handle_netns_event(EventType, [netns()], state()) -> state()
    when EventType :: add_netns | remove_netns | reconcile_netns).
handle_netns_event(remove_netns, ToDel,
        #state{ipvs_mgr=IPVSMgr, route_mgr=RouteMgr, namespaces=Prev}=State) ->
    Namespaces = dcos_l4lb_route_mgr:remove_netns(RouteMgr, ToDel),
    Namespaces = dcos_l4lb_ipvs_mgr:remove_netns(IPVSMgr, ToDel),
    Result = ordsets:subtract(Prev, ordsets:from_list(Namespaces)),
    log_netns_diff(Result, Prev),
    update_gauge(netns, ordsets:size(Result)),
    State#state{namespaces=Result};
handle_netns_event(add_netns, ToAdd,
        #state{ipvs_mgr=IPVSMgr, route_mgr=RouteMgr, namespaces=Prev}=State) ->
    Namespaces = dcos_l4lb_route_mgr:add_netns(RouteMgr, ToAdd),
    Namespaces = dcos_l4lb_ipvs_mgr:add_netns(IPVSMgr, ToAdd),
    Result = ordsets:union(ordsets:from_list(Namespaces), Prev),
    log_netns_diff(Result, Prev),
    update_gauge(netns, ordsets:size(Result)),
    State#state{namespaces=Result};
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
%%% GC funtions
%%%===================================================================

-spec(handle_gc(state()) -> state()).
handle_gc(#state{ipvs_mgr=IPVSMgr, route_mgr=RouteMgr,
                 ipset_mgr=IPSetMgr, netns_mgr=NetNSMgr}=State) ->
    true = erlang:garbage_collect(IPVSMgr),
    true = erlang:garbage_collect(RouteMgr),
    true = erlang:garbage_collect(IPSetMgr),
    true = erlang:garbage_collect(NetNSMgr),
    State.

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

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(update_counter(atom(), non_neg_integer()) -> ok).
update_counter(Name, Value) ->
    prometheus_counter:inc(l4lb, Name, [], Value).

-spec(update_gauge(atom(), non_neg_integer()) -> ok).
update_gauge(Name, Value) ->
    prometheus_gauge:set(l4lb, Name, [], Value).

-spec(update_summary(atom(), non_neg_integer()) -> ok).
update_summary(Name, Value) ->
    prometheus_summary:observe(l4lb, Name, [], Value).

-spec(init_metrics() -> ok).
init_metrics() ->
    ok = dcos_l4lb_ipvs_mgr:init_metrics(),
    ok = dcos_l4lb_route_mgr:init_metrics(),
    ok = dcos_l4lb_ipset_mgr:init_metrics(),
    init_vips_metrics(),
    init_reconciled_metrics(),
    init_unreachable_metrics().

-spec(init_vips_metrics() -> ok).
init_vips_metrics() ->
    prometheus_gauge:new([
        {registry, l4lb},
        {name, vips},
        {help, "The number of VIP labels."}]),
    prometheus_gauge:new([
        {registry, l4lb},
        {name, backends},
        {help, "The number of VIP backends."}]),
    prometheus_gauge:new([
        {registry, l4lb},
        {name, netns},
        {help, "The number of L4LB network namespaces."}]),
    prometheus_summary:new([
        {registry, l4lb},
        {name, vips_duration_seconds},
        {help, "The time spent processing VIPs configuration."}]).

-spec(init_reconciled_metrics() -> ok).
init_reconciled_metrics() ->
    prometheus_counter:new([
        {registry, l4lb},
        {name, reconciled_routes_total},
        {help, "Total number of reconciled routes."}]),
    prometheus_counter:new([
        {registry, l4lb},
        {name, reconciled_ipvs_rules_total},
        {help, "Total number of reconciled IPVS rules."}]),
    prometheus_counter:new([
        {registry, l4lb},
        {name, reconciled_ipset_entries_total},
        {help, "Total number of reconciled IPSet entries."}]).

-spec(init_unreachable_metrics() -> ok).
init_unreachable_metrics() ->
    prometheus_gauge:new([
        {registry, l4lb},
        {name, unreachable_backends},
        {help, "The number of unreachable VIP backends."}]),
    prometheus_gauge:new([
        {registry, l4lb},
        {name, unreachable_vips},
        {help, "The number of unreachable VIPs."}]),
    prometheus_gauge:new([
        {registry, l4lb},
        {name, unreachable_nodes},
        {help, "The number of unreachable nodes."}]).

%%%===================================================================
%%% Test functions
%%%===================================================================

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
        diff([{a, []}, {c, []}], [{b, []}])),
    ?assertEqual(
        {[], [], []},
        diff([{key, [x, y]}], [{key, [y, x]}])).

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
