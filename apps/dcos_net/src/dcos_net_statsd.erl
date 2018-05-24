-module(dcos_net_statsd).
-behaviour(gen_server).

-include_lib("kernel/include/inet.hrl").

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-type metric() :: {iodata(), non_neg_integer() | float()}.
-type swt() :: [{pos_integer(), integer(), integer()}].
-type sysmon() :: #{}.

-record(state, {
    tref :: reference(),
    sysmon :: sysmon(),
    swt :: swt()
}).

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    TRef = start_push_timer(),
    SWT = enable_scheduler_wall_time(),
    SysMon = enable_system_monitor(),
    {ok, #state{tref=TRef, sysmon=SysMon, swt=SWT}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({timeout, TRef0, push}, #state{tref=TRef0,
        sysmon=SysMon, swt=SWTp}=State) ->
    SWTn = scheduler_wall_time(),
    ok = push_metrics({SWTp, SWTn}, SysMon),
    TRef = start_push_timer(),
    {noreply, State#state{tref=TRef, sysmon=#{}, swt=SWTn}};
handle_info({monitor, Pid, Type, Info},
        #state{sysmon=SysMon}=State) when Pid =:= self() ->
    SysMon0 = handle_system_monitor(Type, Info, SysMon),
    {noreply, State#state{sysmon=SysMon0}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_push_timer() -> reference()).
start_push_timer() ->
    Timeout = application:get_env(dcos_net, metrics_push_timeout, 5000),
    Timeout0 = Timeout - erlang:system_time(millisecond) rem Timeout,
    erlang:start_timer(Timeout0, self(), push).

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(push_metrics({swt(), swt()}, sysmon()) -> ok).
push_metrics(SWTs, SysMon) ->
    MetricsInfo = folsom_metrics:get_metrics_info(),
    MetricsInfo0 = filter_metrics(MetricsInfo),
    Metrics = expand_metrics(MetricsInfo0),
    VmMetrics = expand_vm_metrics(SWTs, SysMon),
    send_metrics(VmMetrics ++ Metrics).

-spec(filter_metrics(MetricsInfo) -> MetricsInfo
    when MetricsInfo :: [{Name :: term(), Opts :: list()}]).
filter_metrics(MetricsInfo) ->
    MetricsPrefixes = application:get_env(
        dcos_net, metrics_prefixes,
        [vm, mesos, dns, overlay, l4lb, lashup]),
    [{Name, Opts} || {Name, Opts} <- MetricsInfo, is_tuple(Name),
     lists:member(element(1, Name), MetricsPrefixes)].

-spec(expand_metrics([{Name :: tuple(), Opts :: list()}]) -> [metric()]).
expand_metrics(MetricsInfo) ->
    lists:flatmap(fun expand/1, MetricsInfo).

-spec(expand({Name :: tuple(), Opts :: list()}) -> [metric()]).
expand({Name, Opts}) ->
    Type = proplists:get_value(type, Opts),
    expand(Type, Name).

-spec(expand(Type :: atom(), Name :: tuple()) -> [metric()]).
expand(gauge, Name) ->
    Value = folsom_metrics_gauge:get_value(Name),
    [{to_name(Name), Value}];
expand(counter, Name) ->
    Value = folsom_metrics_counter:get_value(Name),
    [{to_name(Name), Value}];
expand(histogram, Name) ->
    Values = folsom_metrics_histogram:get_values(Name),
    Stats = hist_statistics(Values),
    lists:map(fun ({P, V}) ->
        {to_name(Name, P), V}
    end, Stats).

-spec(to_name(atom() | binary() | non_neg_integer() | tuple()) -> iodata()).
to_name(Atom) when is_atom(Atom) ->
    Bin = atom_to_binary(Atom, latin1),
    binary:replace(Bin, <<".">>, <<"-">>, [global]);
to_name(Bin) when is_binary(Bin) ->
    Bin;
to_name(Num) when is_integer(Num), Num >= 0 ->
    integer_to_binary(Num);
to_name(Tuple) when is_tuple(Tuple) ->
    List = tuple_to_list(Tuple),
    List0 = lists:map(fun to_name/1, List),
    lists:join(".", List0).

-spec(to_name(X, X) -> iodata()
    when X :: atom() | binary() | tuple()).
to_name(Head, Tail) ->
    [to_name(Head), ".", to_name(Tail)].

%%%===================================================================
%%% Statsd functions
%%%===================================================================

-spec(send_metrics([metric()]) -> ok).
send_metrics(Metrics) ->
    Host = application:get_env(dcos_net, statsd_udp_host, undefined),
    Port = application:get_env(dcos_net, statsd_udp_port, undefined),
    send_metrics(Host, Port, Metrics).

-spec(send_metrics(inet:hostname() | undefined,
                   inet:port_number() | undefined,
                   [metric()]) -> ok).
send_metrics(_Host, undefined, _Metrics) ->
    ok;
send_metrics(undefined, _Port, _Metrics) ->
    ok;
send_metrics(Host, Port, Metrics) ->
    {ok, UDPPort} = gen_udp:open(0),
    try
        lists:foreach(fun ({Name, Value}) ->
            % SPEC: https://github.com/b/statsd_spec#gauges
            Data = ["dcos.net.", Name, ":", to_bin(Value), "|g"],
            ok = gen_udp:send(UDPPort, Host, Port, Data)
        end, Metrics)
    after
        gen_udp:close(UDPPort)
    end.

-spec(to_bin(number()) -> binary()).
to_bin(Value) when is_integer(Value) ->
    integer_to_binary(Value);
to_bin(Value) when is_float(Value) ->
    float_to_binary(Value, [{decimals, 2}, compact]).

%%%===================================================================
%%% Histogram functions
%%%===================================================================

-spec(hist_statistics([number()]) -> [{atom(), number()}]).
hist_statistics([]) ->
    [];
hist_statistics(Values) ->
    Size = length(Values),
    Values0 = lists:sort(Values),
    [
        {max, lists:last(Values0)},
        {p99, percentile(Values0, Size, 0.99)},
        {p95, percentile(Values0, Size, 0.95)},
        {p75, percentile(Values0, Size, 0.75)},
        {p50, percentile(Values0, Size, 0.5)},
        {mean, lists:sum(Values0) / Size}
    ].

-spec(percentile([number()], pos_integer(), float()) -> number()).
percentile(Values, Size, Percentile) ->
    Element = round(Percentile * Size),
    lists:nth(Element, Values).

%%%===================================================================
%%% VM functions
%%%===================================================================

-define(STATKEYS, [
    context_switches, garbage_collection, io,
    reductions, runtime, total_active_tasks_all,
    total_run_queue_lengths_all
]).

-define(SYSKEYS, [port_count, process_count]).

-spec(expand_vm_metrics({swt(), swt()}, sysmon()) -> [metric()]).
expand_vm_metrics(SWTs, SysMon) ->
    [{"vm.nodes", length(nodes())}] ++
    lists:flatmap(fun expand_vm_stat/1, ?STATKEYS) ++
    lists:flatmap(fun expand_vm_sysinfo/1, ?SYSKEYS) ++
    lists:map(fun expand_vm_memory/1, erlang:memory()) ++
    expand_vm_utilization(SWTs) ++
    expand_vm_sysmon(SysMon).

-spec(expand_vm_stat(atom()) -> [metric()]).
expand_vm_stat(Key) ->
    Stat = erlang:statistics(Key),
    expand_vm_stat(Key, Stat).

-spec(expand_vm_stat(atom(), term()) -> [metric()]).
expand_vm_stat(context_switches, {CxtSwitches, 0}) ->
    [{"vm.context_switches", CxtSwitches}];
expand_vm_stat(garbage_collection, {Calls, Words, 0}) ->
    [{"vm.gc.calls", Calls}, {"vm.gc.words", Words}];
expand_vm_stat(io, {{input, Input}, {output, Output}}) ->
    [{"vm.io.input", Input}, {"vm.io.output", Output}];
expand_vm_stat(reductions, {N, _SinceLastCall}) ->
    [{"vm.reductions", N}];
expand_vm_stat(runtime, {N, _SinceLastCall}) ->
    [{"vm.runtime", N}];
expand_vm_stat(total_active_tasks_all, N) ->
    [{"vm.tasks.active", N}];
expand_vm_stat(total_run_queue_lengths_all, N) ->
    [{"vm.tasks.queue", N}].

-spec(expand_vm_sysinfo(atom()) -> [metric()]).
expand_vm_sysinfo(Key) ->
    Info = erlang:system_info(Key),
    expand_vm_sysinfo(Key, Info).

-spec(expand_vm_sysinfo(atom(), term()) -> [metric()]).
expand_vm_sysinfo(port_count, N) ->
    [{"vm.ports", N}];
expand_vm_sysinfo(process_count, N) ->
    [{"vm.processes", N}].

-spec(expand_vm_memory({atom(), non_neg_integer()}) -> metric()).
expand_vm_memory({K, N}) ->
    {to_name({vm, memory}, K), N}.

-spec(expand_vm_utilization({swt(), swt()}) -> [metric()]).
expand_vm_utilization({SWTp, SWTn}) ->
    {Metrics, A, T} =
        lists:foldl(fun ({{I, A0, T0}, {I, A1, T1}}, {Mc, Ac, Tc}) ->
            A = A1 - A0,
            T = T1 - T0,
            M = {["vm.utilization.scheduler.", to_bin(I)], A / T},
            {[M | Mc], Ac + A, Tc + T}
        end, {[], 0, 0}, lists:zip(SWTp, SWTn)),
    [{"vm.utilization.total", A / T} | Metrics].

-spec(enable_scheduler_wall_time() -> swt()).
enable_scheduler_wall_time() ->
    _ = erlang:system_flag(scheduler_wall_time, true),
    scheduler_wall_time().

-spec(scheduler_wall_time() -> swt()).
scheduler_wall_time() ->
    N = erlang:system_info(schedulers),
    SWT = lists:keysort(1, erlang:statistics(scheduler_wall_time)),
    lists:takewhile(fun ({I, _A, _T}) -> I =< N end, SWT).

%%%===================================================================
%%% System monitor functions
%%%===================================================================

-spec(enable_system_monitor() -> sysmon()).
enable_system_monitor() ->
    erlang:system_monitor(self(), [
        busy_port, busy_dist_port,
        {long_gc, application:get_env(dcos_net, long_gc_limit, 50)},
        {long_schedule, application:get_env(dcos_net, long_gc_limit, 50)}
    ]),
    #{}.

-spec(handle_system_monitor(atom(), term(), sysmon()) -> sysmon()).
handle_system_monitor(Type, _Port, SysMon)
        when Type =:= busy_port;
             Type =:= busy_dist_port ->
    N = maps:get(Type, SysMon, 0),
    SysMon#{Type => N + 1};
handle_system_monitor(Type, Info, SysMon)
        when Type =:= long_gc;
             Type =:= long_schedule ->
    N = maps:get(Type, SysMon, 0),
    case lists:keyfind(timeout, 1, Info) of
        false -> SysMon;
        {timeout, Timeout} ->
            SysMon#{Type => erlang:max(Timeout, N)}
    end.

-spec(expand_vm_sysmon(sysmon()) -> [metric()]).
expand_vm_sysmon(SysMon) ->
    maps:fold(fun (Key, Value, Acc) ->
        [{to_name({vm, sysmon, Key}), Value} | Acc]
    end, [], SysMon).
