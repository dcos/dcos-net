-module(dcos_net_sysmon).
-behavior(gen_server).

-export([
    start_link/0,
    init_metrics/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3,
    handle_cast/2, handle_info/2]).

-record(state, {}).

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    erlang:system_monitor(self(), [
        busy_port, busy_dist_port,
        {long_gc, application:get_env(dcos_net, long_gc, 10)},
        {long_schedule, application:get_env(dcos_net, long_schedule, 10)}
    ]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({monitor, Pid, long_gc, Info}, State) ->
    {timeout, Timeout} = lists:keyfind(timeout, 1, Info),
    [ lager:warning("sysmon long_gc: ~p, process: ~p", [Info, info(Pid)])
    || Timeout > application:get_env(dcos_net, long_gc_threshold, 100) ],
    prometheus_histogram:observe(erlang_vm_sysmon_long_gc_seconds, Timeout),
    {noreply, State};
handle_info({monitor, Obj, long_schedule, Info}, State) ->
    {timeout, Timeout} = lists:keyfind(timeout, 1, Info),
    [ lager:warning("sysmon long_schedule: ~p, process: ~p", [Info, info(Obj)])
    || Timeout > application:get_env(dcos_net, long_schedule_threshold, 100) ],
    prometheus_histogram:observe(
        erlang_vm_sysmon_long_schedule_seconds, Timeout),
    {noreply, State};
handle_info({monitor, Pid, busy_port, Port}, State) ->
    lager:warning(
        "sysmon busy_port: ~p, process: ~p, port: ~p",
        [recon:port_info(Port), info(Pid), info(Port)]),
    prometheus_counter:inc(erlang_vm_sysmon_busy_port_total, 1),
    {noreply, State};
handle_info({monitor, Pid, busy_dist_port, Port}, State) ->
    lager:warning(
        "sysmon busy_dist_port: ~p, process: ~p, port: ~p",
        [recon:port_info(Port), info(Pid), info(Port)]),
    prometheus_counter:inc(erlang_vm_sysmon_busy_dist_port_total, 1),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

info(Pid) when is_pid(Pid) ->
    recon:info(Pid);
info(Port) when is_port(Port) ->
    recon:port_info(Port).

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(init_metrics() -> ok).
init_metrics() ->
    prometheus_histogram:new([
        {name, erlang_vm_sysmon_long_gc_seconds},
        {duration_unit, seconds},
        {buckets, [0.01, 0.025, 0.05, 0.1, 0.5, 1.0, 5.0]},
        {help, "Erlang VM system monitor for long garbage collection calls."}
    ]),
    prometheus_histogram:new([
        {name, erlang_vm_sysmon_long_schedule_seconds},
        {duration_unit, seconds},
        {buckets, [0.01, 0.025, 0.05, 0.1, 0.5, 1.0, 5.0]},
        {help, "Erlang VM system monitor for long uninterrupted execution."}
    ]),
    prometheus_counter:new([
        {name, erlang_vm_sysmon_busy_port_total},
        {help, "Erlang VM system monitor for busy port events."}
    ]),
    prometheus_counter:new([
        {name, erlang_vm_sysmon_busy_dist_port_total},
        {help, "Erlang VM system monitor for busy dist port events."}
    ]).
