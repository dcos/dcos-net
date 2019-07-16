-module(dcos_net_vm_metrics_collector).
-behaviour(prometheus_collector).
-export([
    init/0,
    deregister_cleanup/1,
    collect_mf/2
]).

-spec(init() -> true).
init() ->
    ets:new(?MODULE, [public, named_table]),
    true.

-spec(deregister_cleanup(term()) -> ok).
deregister_cleanup(_) ->
    ok.

-spec(collect_mf(_Registry, Callback) -> ok
    when _Registry :: prometheus_registry:registry(),
         Callback :: prometheus_collector:callback()).
collect_mf(_Registry, Callback) ->
    lists:foreach(fun ({Name, Help, Type, Metrics}) ->
        MF = prometheus_model_helpers:create_mf(Name, Help, Type, Metrics),
        Callback(MF)
    end, metrics()).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(metrics() -> [{Name, Help, Type, Metrics}]
    when Name :: atom(), Help :: string(),
         Type :: atom(), Metrics :: term()).
metrics() ->
    [{erlang_vm_scheduler_utilization,
        "Erlang VM Scheduler utilization.",
        gauge, utilization()}].

-spec(utilization() -> [{Labels, Util}]
    when Labels :: [{string(), term()}],
         Util :: non_neg_integer()).
utilization() ->
    _ = erlang:system_flag(scheduler_wall_time, true),
    SWT = erlang:statistics(scheduler_wall_time_all),
    PrevSWT =
        case ets:lookup(?MODULE, scheduler_wall_time) of
            [{scheduler_wall_time, Prev}] -> Prev;
            [] -> [{I, 0, 0} || {I, _, _} <- SWT]
        end,
    true = ets:insert(?MODULE, {scheduler_wall_time, SWT}),
    [ {scheduler_labels(Id), min(max(0, U), 1)}
    || {Id, U} <- recon_lib:scheduler_usage_diff(PrevSWT, SWT) ].

-spec(scheduler_labels(pos_integer()) -> [{string(), term()}]).
scheduler_labels(Id) ->
    Schedulers = erlang:system_info(schedulers),
    DirtyCPUs = erlang:system_info(dirty_cpu_schedulers),
    case Id of
        Id when Id =< Schedulers ->
            [{"id", Id}, {"type", "scheduler"}];
        Id when Id =< Schedulers + DirtyCPUs ->
            [{"id", Id}, {"type", "dirty_cpu"}];
        Id ->
            [{"id", Id}, {"type", "dirty_io"}]
    end.
