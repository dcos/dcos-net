-module(dcos_l4lb_mesos).
-behavior(dcos_net_gen_mesos_listener).

-include_lib("kernel/include/logger.hrl").
-include("dcos_l4lb.hrl").

%% API
-export([
    start_link/0
]).

%% dcos_net_gen_mesos_listener callbacks
-export([handle_info/2, handle_reset/1, handle_push/1,
    handle_tasks/1, handle_task_updated/3]).

-export_type([backend/0]).

-type task() :: dcos_net_mesos_listener:task().
-type task_id() :: dcos_net_mesos_listener:task_id().
-type task_port() :: dcos_net_mesos_listener:task_port().
-type key() :: dcos_l4lb_mgr:key().

-type backend() :: #{
    task_id => task_id(),
    agent_ip => inet:ip4_address(),
    task_ip => [inet:ip_address()],
    host_port => inet:port_number(),
    port => inet:port_number(),
    runtime => dcos_net_mesos_listener:runtime()
}.

-record(state, {
    vips = #{} :: vips(),
    tasks = #{} :: #{task_id() => boolean()}
}).
-type vips() :: #{key() => [backend()]}.

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    dcos_net_gen_mesos_listener:start_link({local, ?MODULE}, ?MODULE).

%%%===================================================================
%%% dcos_net_gen_mesos_listener callbacks
%%%===================================================================

handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_reset(_State) ->
    ok.

handle_push(#state{vips=VIPs}) ->
    Op = {assign, VIPs, erlang:system_time(millisecond)},
    {ok, _Info} = lashup_kv:request_op(
        ?VIPS_KEY3, {update, [{update, ?VIPS_FIELD, Op}]}),
    ok.

handle_tasks(Tasks) ->
    maps:fold(fun (TaskId, Task, Acc) ->
        {_Update, Acc0} = handle_task_updated(TaskId, Task, Acc),
        Acc0
    end, #state{}, Tasks).

handle_task_updated(TaskId, Task, #state{tasks = Tasks, vips = VIPs} = State) ->
    IsHealthy = is_healthy(Task),
    case maps:is_key(TaskId, Tasks) of
        IsHealthy ->
            % skip task update
            {false, State};
        false when IsHealthy ->
            Tasks0 = Tasks#{TaskId => true},
            TaskVIPs = get_task_vips(TaskId, Task),
            {Updated, VIPs0} = add_vips(TaskVIPs, VIPs),
            {Updated, State#state{tasks = Tasks0, vips = VIPs0}};
        true when not IsHealthy ->
            Tasks0 = maps:remove(TaskId, Tasks),
            TaskVIPs = get_task_vips(TaskId, Task),
            {Updated, VIPs0} = del_vips(TaskVIPs, VIPs),
            {Updated, State#state{tasks = Tasks0, vips = VIPs0}}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(add_vips([{key(), backend()}], vips()) -> {boolean(), vips()}).
add_vips(TaskVIPs, VIPs) ->
    lists:foldl(fun ({Key, Backend}, {Updated, Acc}) ->
        {Updated0, Acc0} = add_backend(Key, Backend, Acc),
        {Updated orelse Updated0, Acc0}
    end, {false, VIPs}, TaskVIPs).

-spec(add_backend(key(), backend(), vips()) -> {boolean(), vips()}).
add_backend(Key, Backend, VIPs) ->
    case maps:find(Key, VIPs) of
        error ->
            {true, VIPs#{Key => [Backend]}};
        {ok, Value} ->
            case lists:member(Backend, Value) of
                false ->
                    {true, VIPs#{Key => [Backend | Value]}};
                true ->
                    {false, VIPs}
            end
    end.

-spec(del_vips([{key(), backend()}], vips()) -> {boolean(), vips()}).
del_vips(TaskVIPs, VIPs) ->
    lists:foldl(fun ({Key, Backend}, {Updated, Acc}) ->
        {Updated0, Acc0} = del_backend(Key, Backend, Acc),
        {Updated orelse Updated0, Acc0}
    end, {false, VIPs}, TaskVIPs).

-spec(del_backend(key(), backend(), vips()) -> {boolean(), vips()}).
del_backend(Key, Backend, VIPs) ->
    case maps:find(Key, VIPs) of
        error ->
            {false, VIPs};
        {ok, Backends} ->
            case take(Backend, Backends) of
                [] ->
                    {true, maps:remove(Key, VIPs)};
                false ->
                    {false, VIPs};
                Backends0 ->
                    {true, VIPs#{Key => Backends0}}
            end
    end.

-spec(get_task_vips(task_id(), task()) -> [{key(), backend()}]).
get_task_vips(TaskId, Task) ->
    Ports = maps:get(ports, Task, []),
    lists:flatmap(fun (Port) ->
        get_task_vips(TaskId, Task, Port)
    end, Ports).

-spec(get_task_vips(task_id(), task(), task_port()) -> [{key(), backend()}]).
get_task_vips(TaskId, Task, #{protocol := Protocol} = Port) ->
    VIPLabels = maps:get(vip, Port, []),
    lists:flatmap(fun (VIPLabel) ->
        try
            Key = get_key(Protocol, VIPLabel, Task),
            [{Key, get_backend(TaskId, Task, Port)}]
        catch _:_ ->
            ?LOG_ERROR("Skipping bad VIP label: ~s", [VIPLabel]),
            []
        end
    end, VIPLabels).

-spec(get_backend(task_id(), task(), task_port()) -> backend()).
get_backend(TaskId, Task, Port) ->
    VIP_T = maps:with([agent_ip, task_ip, runtime], Task),
    VIP_P = maps:with([port, host_port], Port),
    maps:put(task_id, TaskId, maps:merge(VIP_T, VIP_P)).

-spec(get_key(tcp | udp, binary(), task()) -> key()).
get_key(Protocol, VIPLabel, #{framework := Framework}) ->
    [VIPBin, PortBin] = string:split(VIPLabel, <<":">>, trailing),
    VIPStr = binary_to_list(VIPBin),
    Port = binary_to_integer(PortBin),
    true = is_integer(Port) andalso (Port > 0),
    case inet:parse_strict_address(VIPStr) of
        {ok, VIPIP} ->
            {Protocol, VIPIP, Port};
        _ ->
            {Protocol, {VIPBin, Framework}, Port}
    end.

-spec(is_healthy(task()) -> boolean()).
is_healthy(#{healthy := IsHealthy, state := running}) ->
    IsHealthy;
is_healthy(#{state := running}) ->
    true;
is_healthy(_Task) ->
    false.

-spec(take(A, [A]) -> [A] | false when A :: any()).
take(Element, List) ->
    case lists:member(Element, List) of
        false ->
            false;
        true ->
            lists:delete(Element, List)
    end.
