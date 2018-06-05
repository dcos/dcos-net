%%% @doc Polls the local mesos agent if {dcos_l4lb, agent_polling_enabled} is true

-module(dcos_l4lb_mesos_poller).
-behaviour(gen_server).
-include("dcos_l4lb.hrl").

%% API
-export([
    start_link/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-export_type([named_vip/0, vip/0, protocol/0,
    key/0, lkey/0, backend/0]).

-record(state, {
    timer_ref :: reference()
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
    TRef = start_poll_timer(),
    {ok, #state{timer_ref=TRef}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({timeout, TRef, poll}, #state{timer_ref=TRef}=State) ->
    TRef0 = start_poll_timer(),
    ok = handle_poll(),
    {noreply, State#state{timer_ref=TRef0}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_poll_timer() -> reference()).
start_poll_timer() ->
    Timeout = dcos_l4lb_config:agent_poll_interval(),
    erlang:start_timer(Timeout, self(), poll).

-spec(handle_poll() -> ok).
handle_poll() ->
    IsEnabled = dcos_l4lb_config:agent_polling_enabled(),
    handle_poll(IsEnabled).

-spec(handle_poll(boolean()) -> ok).
handle_poll(false) ->
    ok;
handle_poll(true) ->
    case dcos_net_mesos_listener:poll() of
        {error, Error} ->
            lager:warning("Unable to poll agent: ~p", [Error]);
        {ok, Tasks} ->
            handle_poll_state(Tasks)
    end.

-spec(handle_poll_state(#{task_id() => task()}) -> ok).
handle_poll_state(Tasks) ->
    Tasks0 = maps:filter(fun is_healthy/2, Tasks),

    PortMappings = collect_port_mappings(Tasks0),
    dcos_l4lb_mgr:local_port_mappings(PortMappings),

    VIPs = collect_vips(Tasks0),
    ok = push_vips(VIPs).

-spec(is_healthy(task_id(), task()) -> boolean()).
is_healthy(_TaskId, Task) ->
    is_healthy(Task).

-spec(is_healthy(task()) -> boolean()).
is_healthy(#{state := running}) ->
    true;
is_healthy(#{state := {running, IsHealthy}}) ->
    IsHealthy;
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
        [TaskIP | _TaskIPs] = maps:get(task_ip, Task),
        PMs = [{{Protocol, Host}, {TaskIP, Port}}
              || #{host_port := Host, protocol := Protocol,
                   port := Port} <- maps:get(ports, Task, [])],
        PMs ++ Acc
    end, [], Tasks).

-spec(collect_vips(#{task_id() => task()}) -> #{key() => [backend()]}).
collect_vips(Tasks) ->
    maps:fold(fun collect_vips/3, #{}, Tasks).

-spec(collect_vips(task_id(), task(), VIPs) -> VIPs
    when VIPs :: #{key() => [backend()]}).
collect_vips(_TaskId, Task, VIPs) ->
    lists:foldl(fun (Port, Acc) ->
        lists:foldl(fun (VIPLabel, Bcc) ->
            Key = key(Task, Port, VIPLabel),
            Value = backends(Task, Port),
            mappend(Key, Value, Bcc)
        end, Acc, maps:get(vip, Port, []))
    end, VIPs, maps:get(ports, Task, [])).

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

-spec(backends(task(), task_port()) -> [backend()]).
backends(Task, PortObj) ->
    IsIPv6Enabled = application:get_env(dcos_l4lb, enable_ipv6, true),
    AgentIP = maps:get(agent_ip, Task),
    case maps:find(host_port, PortObj) of
        error ->
            Port = maps:get(port, PortObj),
            [{AgentIP, {TaskIP, Port}}
            || TaskIP <- maps:get(task_ip, Task),
            dcos_l4lb_app:family(TaskIP) =:= inet orelse
            IsIPv6Enabled];
        {ok, HostPort} ->
            [{AgentIP, {AgentIP, HostPort}}]
    end.

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
    push_ops(?VIPS_KEY2, Ops).

-spec(generate_ops(#{key() => [backend()]}, [{lkey(), [backend()]}]) ->
    [riak_dt_map:map_field_update()]).
generate_ops(LocalVIPs, VIPs) ->
    AgentIP = dcos_net_dist:nodeip(),
    {Ops, LocalVIPs0} =
        lists:foldl(
            fun ({{Key, riak_dt_orswot} = LKey, Backends}, {Acc, LVIPs}) ->
                {LBackends, LVIPs0} = mtake(Key, LVIPs, []),
                case generate_backend_ops(AgentIP, LBackends, Backends) of
                    [] -> {Acc, LVIPs0};
                    Ops -> {[{update, LKey, {update, Ops}}|Acc], LVIPs0}
                end
            end, {[], LocalVIPs}, VIPs),
    maps:fold(fun (Key, Backends, Acc) ->
        LKey = {Key, riak_dt_orswot},
        [{update, LKey, {add_all, Backends}} | Acc]
    end, Ops, LocalVIPs0).

-spec(generate_backend_ops(inet:ip4_address(), [backend()], [backend()]) ->
    [riak_dt_orswot:orswot_op()]).
generate_backend_ops(AgentIP, LocalBackends, Backends) ->
    Backends0 = [B || {IP, _Backend} = B <- Backends, IP =:= AgentIP],
    {Added, Removed} = dcos_net_utils:complement(LocalBackends, Backends0),
    AddOps = [{add_all, Added} || Added =/= []],
    RemoveOps = [{remove_all, Removed} || Removed =/= []],
    AddOps ++ RemoveOps.

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
