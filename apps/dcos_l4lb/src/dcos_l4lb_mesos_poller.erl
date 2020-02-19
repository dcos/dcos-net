%%% @doc Polls the local mesos agent if {dcos_l4lb, agent_polling_enabled} is true

-module(dcos_l4lb_mesos_poller).
-behaviour(gen_server).

-include("dcos_l4lb.hrl").
-include_lib("kernel/include/logger.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
    start_link/0,
    init_metrics/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3,
    handle_cast/2, handle_info/2, handle_continue/2]).

-export_type([named_vip/0, vip/0, protocol/0,
    key/0, lkey/0, backend/0]).

-record(state, {
    backoff :: backoff:backoff(),
    timer_ref = make_ref() :: reference()
}).

-type task() :: dcos_net_mesos_listener:task().
-type task_id() :: dcos_net_mesos_listener:task_id().
-type task_port() :: dcos_net_mesos_listener:task_port().

-type named_vip() :: {name, {VIPLabel :: binary(), Framework :: binary()}}.
-type vip() :: inet:ip_address() | named_vip().
-type protocol() :: tcp | udp.
-type key() :: {protocol(), vip(), inet:port_number()}.
-type lkey() :: {key(), riak_dt_orswot}.
-type backend() :: {
    AgentIP :: inet:ip4_address(),
    {BackendIP :: inet:ip_address(), BackendPort :: inet:port_number() }
}.

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    PollInterval = dcos_l4lb_config:agent_poll_interval(),
    PollMaxInterval = dcos_l4lb_config:agent_poll_max_interval(),
    Backoff0 = backoff:init(PollInterval, PollMaxInterval, self(), poll),
    Backoff = backoff:type(Backoff0, jitter),
    {ok, #state{backoff = Backoff}, {continue, poll}}.

handle_call(Request, _From, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {reply, ok, State}.

handle_cast(Request, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {noreply, State}.

handle_info({timeout, TRef, poll}, #state{timer_ref = TRef} = State) ->
    {noreply, State, {continue, poll}};
handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_continue(poll, #state{backoff = Backoff0} = State) ->
    {Backoff, TimerRef} = handle_poll(Backoff0),
    {noreply, State#state{backoff = Backoff, timer_ref = TimerRef}, hibernate};
handle_continue(Request, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(handle_poll(backoff:backoff()) -> {backoff:backoff(), reference()}).
handle_poll(Backoff) ->
    IsEnabled = dcos_l4lb_config:agent_polling_enabled(),
    handle_poll(IsEnabled, Backoff).

-spec(handle_poll(boolean(), backoff:backoff()) ->
    {backoff:backoff(), reference()}).
handle_poll(false, Backoff0) ->
    TimerRef = backoff:fire(Backoff0),
    {_, Backoff} = backoff:succeed(Backoff0),
    {Backoff, TimerRef};
handle_poll(true, Backoff0) ->
    try dcos_net_mesos_listener:poll() of
        {error, Error} ->
            TimerRef = backoff:fire(Backoff0),
            {_, Backoff} = backoff:fail(Backoff0),
            ?LOG_WARNING("Unable to poll mesos agent: ~p", [Error]),
            {Backoff, TimerRef};
        {ok, Tasks} ->
            handle_poll_state(Tasks),
            TimerRef = backoff:fire(Backoff0),
            {_, Backoff} = backoff:succeed(Backoff0),
            {Backoff, TimerRef}
    catch error:bad_agent_id ->
        ?LOG_WARNING("Mesos agent is not ready"),
        TimerRef = backoff:fire(Backoff0),
        {_, Backoff} = backoff:succeed(Backoff0),
        {Backoff, TimerRef}
    end.

-spec(handle_poll_state(#{task_id() => task()}) -> ok).
handle_poll_state(Tasks) ->
    HealthyTasks = maps:filter(fun is_healthy/2, Tasks),

    PortMappings = collect_port_mappings(HealthyTasks),
    dcos_l4lb_mgr:local_port_mappings(PortMappings),

    VIPs = collect_vips(HealthyTasks),
    ok = push_vips(VIPs),

    LocalBackends = lists:sum([length(BEs) || BEs <- maps:values(VIPs)]),
    prometheus_gauge:set(l4lb, local_tasks, [], maps:size(Tasks)),
    prometheus_gauge:set(l4lb, local_healthy_tasks, [], maps:size(HealthyTasks)),
    prometheus_gauge:set(l4lb, local_vips, [], maps:size(VIPs)),
    prometheus_gauge:set(l4lb, local_backends, [], LocalBackends).

-spec(is_healthy(task_id(), task()) -> boolean()).
is_healthy(_TaskId, Task) ->
    is_healthy(Task).

-spec(is_healthy(task()) -> boolean()).
is_healthy(#{healthy := IsHealthy, state := running}) ->
    IsHealthy;
% NOTE(jkoelker): when the state is `killing` we specifically ignore health
%                 checks, since mesos stops checking when the task transitions
%                 to `killing`.
is_healthy(#{state := killing}) ->
    true;
is_healthy(#{state := running}) ->
    true;
is_healthy(_Task) ->
    false.

%%%===================================================================
%%% Collect functions
%%%===================================================================

-spec(collect_port_mappings(#{task_id() => task()}) -> #{Host => Container}
    when Host :: {protocol(), inet:port_number()},
         Container :: {inet:ip_address(), inet:port_number()}).
collect_port_mappings(Tasks) ->
    maps:fold(fun (_TaskId, Task, Acc) ->
        Runtime = maps:get(runtime, Task),
        [TaskIP | _TaskIPs] = maps:get(task_ip, Task),
        PMs = [{{Protocol, Host}, {TaskIP, Port}}
              || #{host_port := Host, protocol := Protocol,
                   port := Port} <- maps:get(ports, Task, []),
                 Runtime =/= docker],
        PMs ++ Acc
    end, [], Tasks).

-spec(collect_vips(#{task_id() => task()}) -> #{key() => [backend()]}).
collect_vips(Tasks) ->
    maps:fold(fun collect_vips/3, #{}, Tasks).

-spec(collect_vips(task_id(), task(), VIPs) -> VIPs
    when VIPs :: #{key() => [backend()]}).
collect_vips(TaskId, Task, VIPs) ->
    lists:foldl(fun (Port, Acc) ->
        lists:foldl(fun (VIPLabel, Bcc) ->
            collect_vips(TaskId, Task, Port, VIPLabel, Bcc)
        end, Acc, maps:get(vip, Port, []))
    end, VIPs, maps:get(ports, Task, [])).

-spec(collect_vips(task_id(), task(), task_port(), VIPLabel, VIPs) -> VIPs
    when VIPs :: #{key() => [backend()]}, VIPLabel :: binary()).
collect_vips(TaskId, Task, Port, VIPLabel, VIPs) ->
    try
        Key = key(Task, Port, VIPLabel),
        Value = backends(Key, Task, Port),
        mappend(Key, Value, VIPs)
    catch Class:Error ->
        ?LOG_ERROR("Unexpected error with ~s [~p]: ~p",
                   [TaskId, Class, Error]),
        VIPs
    end.

-spec(key(task(), task_port(), VIPLabel :: binary()) -> key()).
key(Task, PortObj, VIPLabel) ->
    Protocol = maps:get(protocol, PortObj),
    [VIPBin, PortBin] = string:split(VIPLabel, <<":">>, trailing),
    VIPStr = binary_to_list(VIPBin),
    Port = binary_to_integer(PortBin),
    true = is_integer(Port) andalso (Port > 0),
    case inet:parse_strict_address(VIPStr) of
        {ok, VIPIP} ->
            {Protocol, VIPIP, Port};
        _ ->
            Framework = maps:get(framework, Task),
            NamedVIP = {name, {VIPBin, Framework}},
            {Protocol, NamedVIP, Port}
    end.

-spec(backends(key(), task(), task_port()) -> [backend()]).
backends(Key, Task, PortObj) ->
    IsIPv6Enabled = dcos_l4lb_config:ipv6_enabled(),
    AgentIP = maps:get(agent_ip, Task),
    case maps:find(host_port, PortObj) of
        error ->
            Port = maps:get(port, PortObj),
            [ {AgentIP, {TaskIP, Port}}
            || TaskIP <- maps:get(task_ip, Task),
               validate_backend_ip(IsIPv6Enabled, Key, TaskIP) ];
        {ok, HostPort} ->
            [{AgentIP, {AgentIP, HostPort}}]
    end.

-spec(validate_backend_ip(boolean(), key(), inet:ip_address()) -> boolean()).
validate_backend_ip(true, {_Protocol, {name, _Name}, _VIPPort}, _TaskIP) ->
    true;
validate_backend_ip(false, {_Protocol, {name, _Name}, _VIPPort}, TaskIP) ->
    dcos_l4lb_app:family(TaskIP) =:= inet;
validate_backend_ip(true, {_Protocol, VIP, _VIPPort}, TaskIP) ->
    dcos_l4lb_app:family(VIP) =:= dcos_l4lb_app:family(TaskIP);
validate_backend_ip(false, {_Protocol, VIP, _VIPPort}, TaskIP) ->
    {dcos_l4lb_app:family(VIP), dcos_l4lb_app:family(TaskIP)} =:= {inet, inet}.

-spec(mappend(Key, Value, Map) -> Map
    when Key :: term(), Value :: term(),
         Map :: #{Key => Value}).
mappend(Key, Value, Map) ->
    maps:update_with(Key, fun (List) ->
        Value ++ List
    end, Value, Map).

%%%===================================================================
%%% Push functions
%%%===================================================================

-spec(push_vips(#{key() => [backend()]}) -> ok).
push_vips(LocalVIPs) ->
    VIPs = lashup_kv:value(?VIPS_KEY2),
    Ops = generate_ops(LocalVIPs, VIPs),
    push_ops(?VIPS_KEY2, Ops),
    log_ops(Ops).

-spec(generate_ops(#{key() => [backend()]}, [{lkey(), [backend()]}]) ->
    [riak_dt_map:map_field_update()]).
generate_ops(LocalVIPs, VIPs) ->
    AgentIP = dcos_net_dist:nodeip(),
    {Ops, LocalVIPs0} =
        lists:foldl(fun (VIP, {Ops, LVIPs}) ->
            generate_vip_ops(AgentIP, LVIPs, VIP, Ops)
        end, {[], LocalVIPs}, VIPs),
    maps:fold(fun (Key, Backends, Acc) ->
        LKey = {Key, riak_dt_orswot},
        [{update, LKey, {add_all, Backends}} | Acc]
    end, Ops, LocalVIPs0).

-spec(generate_vip_ops(inet:ip4_address(), #{key() => [backend()]},
    {lkey(), [backend()]}, [riak_dt_orswot:orswot_op()]) ->
    {[riak_dt_map:map_field_update()], #{key() => [backend()]}}).
generate_vip_ops(AgentIP, LocalVIPs, VIP, Ops) ->
    {{Key, riak_dt_orswot} = LKey, Backends} = VIP,
    {LocalBackends, LocalVIPs0} = mtake(Key, LocalVIPs, []),
    {PrevLocalBackends, RemoteBackends} =
        lists:partition(fun ({IP, _B}) -> IP =:= AgentIP end, Backends),
    {Added, Removed} =
        dcos_net_utils:complement(LocalBackends, PrevLocalBackends),
    AddOps = [{add_all, Added} || Added =/= []],
    RemoveOps = [{remove_all, Removed} || Removed =/= []],
    case {LocalBackends, RemoteBackends, AddOps ++ RemoveOps} of
        {[], [], _BackendOps} ->
            %% There is no single backend for the VIP in question,
            %% hence the VIP is to be dropped completely in order
            %% to avoid unbounded growth of the state and messages
            %% that are exchanged among dcos-net nodes.
            {[{remove, LKey} | Ops], LocalVIPs0};
        {LocalBackends, RemoteBackends, []} ->
            {Ops, LocalVIPs0};
        {LocalBackends, RemoteBackends, BackendOps} ->
            {[{update, LKey, {update, BackendOps}} | Ops], LocalVIPs0}
    end.

-spec(mtake(Key, Map, Value) -> {Value, Map}
    when Key :: term(), Value :: term(),
         Map :: #{Key => Value}).
mtake(Key, Map, Default) ->
    case maps:take(Key, Map) of
        {Value, Map0} -> {Value, Map0};
        error -> {Default, Map}
    end.

-spec(push_ops(Key :: term(), [riak_dt_map:map_field_update()]) -> ok).
push_ops(_Key, []) ->
    ok;
push_ops(Key, Ops) ->
    {ok, _} = lashup_kv:request_op(Key, {update, Ops}),
    ok.

-spec(log_ops([riak_dt_map:map_field_update()]) -> ok).
log_ops(Ops) ->
    lists:foreach(
        fun ({update, {VIPKey, riak_dt_orswot}, VIPOps}) ->
                log_update_ops(VIPKey, VIPOps);
            ({remove, {VIPKey, riak_dt_orswot}}) ->
                log_remove_op(VIPKey)
        end, Ops).

-spec(log_update_ops(key(), riak_dt_orswot:orswot_op()) -> ok).
log_update_ops(Key, {update, Ops}) ->
    lists:foreach(fun (Op) ->
        log_update_ops(Key, Op)
    end, Ops);
log_update_ops(Key, {add_all, Backends}) ->
    lists:foreach(fun ({_AgentIP, Backend}) ->
        ?LOG_NOTICE("VIP updated: ~p, added: ~p", [Key, Backend])
    end, Backends);
log_update_ops(Key, {remove_all, Backends}) ->
    lists:foreach(fun ({_AgentIP, Backend}) ->
        ?LOG_NOTICE("VIP updated: ~p, removed: ~p", [Key, Backend])
    end, Backends).

-spec(log_remove_op(key()) -> ok).
log_remove_op(Key) ->
    ?LOG_NOTICE("VIP removed: ~p", [Key]).


%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(init_metrics() -> ok).
init_metrics() ->
    prometheus_gauge:new([
        {registry, l4lb},
        {name, local_vips},
        {help, "The number of local VIP labels."}]),
    prometheus_gauge:new([
        {registry, l4lb},
        {name, local_tasks},
        {help, "The number of local tasks."}]),
    prometheus_gauge:new([
        {registry, l4lb},
        {name, local_healthy_tasks},
        {help, "The number of local healthy tasks."}]),
    prometheus_gauge:new([
        {registry, l4lb},
        {name, local_backends},
        {help, "The number of local VIP backends."}]).

%%%===================================================================
%%% Test functions
%%%===================================================================

-ifdef(TEST).

validate_backend_ip_test() ->
    NamedVIP = {tcp, {name, {<<"foo">>, <<"bar">>}}, 80},
    IPv4VIP = {tcp, {11, 2, 3, 4}, 80},
    IPv6VIP = {tcp, {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, 80},
    {ok, IPv4} = inet:parse_address("10.3.2.1"),
    {ok, IPv6} = inet:parse_address("fe80::1"),

    % IPv4
    ?assert(validate_backend_ip(false, NamedVIP, IPv4)),
    ?assert(validate_backend_ip(false, IPv4VIP, IPv4)),
    ?assertNot(validate_backend_ip(false, IPv6VIP, IPv4)),
    ?assert(validate_backend_ip(true, NamedVIP, IPv4)),
    ?assert(validate_backend_ip(true, IPv4VIP, IPv4)),
    ?assertNot(validate_backend_ip(true, IPv6VIP, IPv4)),

    % IPv6
    ?assertNot(validate_backend_ip(false, NamedVIP, IPv6)),
    ?assertNot(validate_backend_ip(false, IPv4VIP, IPv6)),
    ?assertNot(validate_backend_ip(false, IPv6VIP, IPv6)),
    ?assert(validate_backend_ip(true, NamedVIP, IPv6)),
    ?assertNot(validate_backend_ip(true, IPv4VIP, IPv6)),
    ?assert(validate_backend_ip(true, IPv6VIP, IPv6)).

-endif.
