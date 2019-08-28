-module(dcos_dns_mesos).
-behavior(gen_server).

-include("dcos_dns.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("dns/include/dns.hrl").

%% API
-export([
    start_link/0,
    push_zone/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3,
    handle_cast/2, handle_info/2, handle_continue/2]).

-type task() :: dcos_net_mesos_listener:task().
-type task_id() :: dcos_net_mesos_listener:task_id().

-record(state, {
    ref = undefined :: undefined | reference(),
    tasks = #{} :: #{task_id() => [dns:dns_rr()]},
    records = #{} :: #{dns:dns_rr() => pos_integer()},
    records_by_name = #{} :: #{dns:dname() => [dns:dns_rr()]},
    masters_ref = undefined :: undefined | reference(),
    masters = [] :: [dns:dns_rr()],
    ops_ref = undefined :: reference() | undefined,
    ops = [] :: [riak_dt_orswot:orswot_op()]
}).
-type state() :: #state{}.

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, #state{}, {continue, init}}.

handle_call(Request, _From, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {reply, ok, State}.

handle_cast(Request, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {noreply, State}.

handle_info({{tasks, MTasks}, Ref}, #state{ref = Ref} = State0) ->
    {noreply, handle_tasks(MTasks, State0)};
handle_info({{task_updated, TaskId, Task}, Ref}, #state{ref = Ref} = State) ->
    ok = dcos_net_mesos_listener:next(Ref),
    {noreply, handle_task_updated(TaskId, Task, State)};
handle_info({eos, Ref}, #state{ref = Ref} = State) ->
    {noreply, reset_state(State)};
handle_info({'DOWN', Ref, process, _Pid, Info}, #state{ref = Ref} = State) ->
    {stop, Info, State};
handle_info({timeout, _Ref, init}, #state{ref = undefined} = State) ->
    {noreply, State, {continue, init}};
handle_info({timeout, Ref, masters}, #state{masters_ref = Ref} = State) ->
    {noreply, handle_masters(State)};
handle_info({timeout, Ref, push_ops}, #state{ops_ref = Ref} = State) ->
    {noreply, handle_push_ops(State), hibernate};
handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_continue(init, State) ->
    case dcos_net_mesos_listener:subscribe() of
        {ok, Ref} ->
            {noreply, State#state{ref = Ref}};
        {error, timeout} ->
            exit(timeout);
        {error, subscribed} ->
            exit(subscribed);
        {error, _Error} ->
            timer:sleep(100),
            {noreply, State, {continue, init}}
    end;
handle_continue(Request, State) ->
    ?LOG_WARNING("Unexpected request: ~p", [Request]),
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(reset_state(state()) -> state()).
reset_state(#state{ref = Ref, masters_ref = MastersRef, ops_ref = OpsRef}) ->
    case MastersRef of
        undefined -> ok;
        _ -> erlang:cancel_timer(MastersRef)
    end,
    case OpsRef of
        undefined-> ok;
        _ -> erlang:cancel_timer(OpsRef)
    end,
    #state{ref = Ref}.

%%%===================================================================
%%% Tasks functions
%%%===================================================================

-spec(handle_tasks(#{task_id => task()}, state()) -> state()).
handle_tasks(MTasks, State) ->
    MRef = start_masters_timer(),
    {Tasks, Records, RecordsByName} = task_records(MTasks),
    ok = push_zone(?DCOS_DOMAIN, RecordsByName),
    ?LOG_NOTICE("DC/OS DNS Sync: ~p records", [maps:size(Records)]),
    State#state{tasks = Tasks, records = Records,
        records_by_name = RecordsByName, masters_ref = MRef}.

-spec(handle_task_updated(task_id(), task(), state()) -> state()).
handle_task_updated(TaskId, Task, #state{
        tasks = Tasks, records = Records,
        records_by_name = RecordsByName} = State) ->
    {Tasks0, Records0, RecordsByName0, Ops} =
        task_updated(TaskId, Task, Tasks, Records, RecordsByName),
    handle_push_ops(Ops, State#state{
        tasks = Tasks0, records = Records0,
        records_by_name = RecordsByName0}).

-spec(task_updated(task_id(), task(), Tasks, Records, RecordsByName) ->
    {Tasks, Records, RecordsByName, Ops}
    when Tasks :: #{task_id() => [dns:dns_rr()]},
         Records :: #{dns:dns_rr() => pos_integer()},
         RecordsByName :: #{dns:dns_rr() => pos_integer()},
         Ops :: [riak_dt_orswot:orswot_op()]).
task_updated(TaskId, Task, Tasks, Records, RecordsByName) ->
    TaskState = maps:get(state, Task),
    case {is_running(TaskState), maps:is_key(TaskId, Tasks)} of
        {Same, Same} ->
            {Tasks, Records, RecordsByName, []};
        {false, true} ->
            {TaskRRs, Tasks0} = maps:take(TaskId, Tasks),
            Records0 = update_records(TaskRRs, -1, Records),
            % Remove records if there is no another task with such records
            TaskRRs0 = [RR || RR <- TaskRRs, not maps:is_key(RR, Records0)],
            RecordsByName0 = remove_from_index(TaskRRs0, RecordsByName),
            Ops = [{remove_all, TaskRRs0} || TaskRRs0 =/= []],
            {Tasks0, Records0, RecordsByName0, Ops};
        {true, false} ->
            TaskRRs = task_records(TaskId, Task),
            Tasks0 = maps:put(TaskId, TaskRRs, Tasks),
            Records0 = update_records(TaskRRs, 1, Records),
            % Add only new records that are not in `Records` before
            TaskRRs0 = [RR || RR <- TaskRRs, not maps:is_key(RR, Records)],
            RecordsByName0 = add_to_index(TaskRRs0, RecordsByName),
            Ops = [{add_all, TaskRRs0}],
            {Tasks0, Records0, RecordsByName0, Ops}
    end.

-type task_records_ret() ::
    { #{task_id() => [dns:dns_rr()]},
      #{dns:dns_rr() => pos_integer()},
      #{dns:dname() => [dns:dns_rr()]} }.

-spec(task_records(#{task_id() => task()}) -> task_records_ret()).
task_records(Tasks) ->
    InitRecords = #{
        dcos_dns:ns_record(?DCOS_DOMAIN) => 1,
        dcos_dns:soa_record(?DCOS_DOMAIN) => 1,
        leader_record(?DCOS_DOMAIN) => 1
    },
    InitRecordsByName =
        add_to_index(maps:keys(InitRecords), #{}),
    maps:fold(
        fun task_records_fold/3,
        {#{}, InitRecords, InitRecordsByName},
        Tasks).

-spec(task_records_fold(task_id(), task(), Acc) -> Acc
    when Acc :: task_records_ret()).
task_records_fold(
        TaskId, #{state := TaskState} = Task,
        {Tasks, Records, RecordsByName}) ->
    case is_running(TaskState) of
        true ->
            TaskRRs = task_records(TaskId, Task),
            Tasks0 = maps:put(TaskId, TaskRRs, Tasks),
            Records0 = update_records(TaskRRs, 1, Records),
            TaskRRs0 = [RR || RR <- TaskRRs, not maps:is_key(RR, Records)],
            RecordsByName0 = add_to_index(TaskRRs0, RecordsByName),
            {Tasks0, Records0, RecordsByName0};
        false ->
            {Tasks, Records, RecordsByName}
    end.

-spec(task_records(task_id(), task()) -> dns:dns_rr()).
task_records(TaskId, Task) ->
    lists:flatten([
        task_agentip(TaskId, Task),
        task_containerip(TaskId, Task),
        task_autoip(TaskId, Task)
    ]).

-spec(task_agentip(task_id(), task()) -> [dns:dns_rr()]).
task_agentip(_TaskId, #{name := Name,
        framework := Fwrk, agent_ip := AgentIP}) ->
    DName = format_name([Name, Fwrk, <<"agentip">>], ?DCOS_DOMAIN),
    dcos_dns:dns_records(DName, [AgentIP]);
task_agentip(TaskId, Task) ->
    ?LOG_WARNING("Unexpected task ~p with ~p", [TaskId, Task]),
    [].

-spec(task_containerip(task_id(), task()) -> [dns:dns_rr()]).
task_containerip(_TaskId, #{name := Name,
        framework := Fwrk, task_ip := TaskIPs}) ->
    DName = format_name([Name, Fwrk, <<"containerip">>], ?DCOS_DOMAIN),
    dcos_dns:dns_records(DName, TaskIPs);
task_containerip(_TaskId, _Task) ->
    [].

-spec(task_autoip(task_id(), task()) -> [dns:dns_rr()]).
task_autoip(_TaskId, #{name := Name, framework := Fwrk,
        agent_ip := AgentIP, task_ip := TaskIPs} = Task) ->
    %% if task.port_mappings then agent_ip else task_ip
    DName = format_name([Name, Fwrk, <<"autoip">>], ?DCOS_DOMAIN),
    Ports = maps:get(ports, Task, []),
    dcos_dns:dns_records(DName,
        case lists:any(fun is_port_mapping/1, Ports) of
            true -> [AgentIP];
            false -> TaskIPs
        end
    );
task_autoip(_TaskId, #{name := Name,
        framework := Fwrk, agent_ip := AgentIP}) ->
    DName = format_name([Name, Fwrk, <<"autoip">>], ?DCOS_DOMAIN),
    dcos_dns:dns_records(DName, [AgentIP]);
task_autoip(TaskId, Task) ->
    ?LOG_WARNING("Unexpected task ~p with ~p", [TaskId, Task]),
    [].

-spec(is_running(dcos_net_mesos_listener:task_state()) -> boolean()).
is_running(running) ->
    true;
is_running(_TaskState) ->
    false.

-spec(is_port_mapping(dcos_net_mesos_listener:task_port()) -> boolean()).
is_port_mapping(#{host_port := _HPort}) ->
    true;
is_port_mapping(_Port) ->
    false.

-spec(update_records([dns:dns_rr()], integer(), RRs) -> RRs
    when RRs :: #{dns:dns_rr() => pos_integer()}).
update_records(Records, Incr, RRs) when is_list(Records) ->
    lists:foldl(fun (Record, Acc) ->
        update_record(Record, Incr, Acc)
    end, RRs, Records).

-spec(update_record(dns:dns_rr(), integer(), RRs) -> RRs
    when RRs :: #{dns:dns_rr() => pos_integer()}).
update_record(Record, Incr, RRs) ->
    case maps:get(Record, RRs, 0) + Incr of
        0 -> maps:remove(Record, RRs);
        N -> RRs#{Record => N}
    end.

-spec(add_to_index(RRs, RecordsByName) -> RecordsByName
    when RRs :: [dns:dns_rr()], RecordsByName :: #{dns:dname() => RRs}).
add_to_index([], RecordsByName) ->
    RecordsByName;
add_to_index(RRs, RecordsByName) ->
    lists:foldl(fun (#dns_rr{name = Name} = RR, Acc) ->
        Acc#{Name => [RR | maps:get(Name, Acc, [])]}
    end, RecordsByName, RRs).

-spec(remove_from_index(RRs, RecordsByName) -> RecordsByName
    when RRs :: [dns:dns_rr()], RecordsByName :: #{dns:dname() => RRs}).
remove_from_index([], RecordsByName) ->
    RecordsByName;
remove_from_index(RRs, RecordsByName) ->
    lists:foldl(fun (#dns_rr{name = Name} = RR, Acc) ->
        Acc#{Name => lists:delete(RR, maps:get(Name, Acc))}
    end, RecordsByName, RRs).

%%%===================================================================
%%% Masters functions
%%%===================================================================

-spec(handle_masters(state()) -> state()).
handle_masters(#state{
    masters = MRRs, records_by_name = RecordsByName} = State) ->
    ZoneName = ?DCOS_DOMAIN,
    MRRs0 = master_records(ZoneName),

    {NewRRs, OldRRs} = dcos_net_utils:complement(MRRs0, MRRs),
    lists:foreach(fun (#dns_rr{data = #dns_rrdata_a{ip = IP}}) ->
        ?LOG_NOTICE("DNS records: master ~p was added", [IP])
    end, NewRRs),
    lists:foreach(fun (#dns_rr{data = #dns_rrdata_a{ip = IP}}) ->
        ?LOG_NOTICE("DNS records: master ~p was removed", [IP])
    end, OldRRs),

    RecordsByName0 = add_to_index(NewRRs, RecordsByName),
    RecordsByName1 = remove_from_index(OldRRs, RecordsByName0),
    State0 = State#state{
        masters = MRRs0,
        masters_ref = start_masters_timer(),
        records_by_name = RecordsByName1},
    Ops = [{add_all, NewRRs} || NewRRs =/= []] ++
          [{remove_all, OldRRs} || OldRRs =/= []],
    handle_push_ops(Ops, State0).

-spec(master_records(dns:dname()) -> [dns:dns_rr()]).
master_records(ZoneName) ->
    Masters = [IP || {IP, _} <- dcos_dns_config:mesos_resolvers()],
    dcos_dns:dns_records(<<"master.", ZoneName/binary>>, Masters).

-spec(leader_record(dns:dname()) -> dns:dns_rr()).
leader_record(ZoneName) ->
    % dcos-net connects only to local mesos,
    % operator API works only on a leader mesos,
    % so this node is the leader node
    IP = dcos_net_dist:nodeip(),
    dcos_dns:dns_record(<<"leader.", ZoneName/binary>>, IP).

-spec(start_masters_timer() -> reference()).
start_masters_timer() ->
    Timeout = application:get_env(dcos_dns, masters_timeout, 5000),
    erlang:start_timer(Timeout, self(), masters).

%%%===================================================================
%%% DNS functions
%%%===================================================================

-spec(format_name([binary()], binary()) -> binary()).
format_name(ListOfNames, Postfix) ->
    ListOfNames1 = lists:map(fun mesos_state:label/1, ListOfNames),
    ListOfNames2 = lists:map(fun list_to_binary/1, ListOfNames1),
    Prefix = dcos_net_utils:join(ListOfNames2, <<".">>),
    <<Prefix/binary, ".", Postfix/binary>>.

%%%===================================================================
%%% Lashup functions
%%%===================================================================

-spec(push_zone(dns:dname(), #{dns:dname() => [dns:dns_rr()]}) -> ok).
push_zone(ZoneName, RecordsByName) ->
    Modes = dcos_dns_config:store_modes(),
    lists:foldl(
        fun (lww, _Acc) ->
                push_lww_zone(ZoneName, RecordsByName);
            (set, _Acc) ->
                Records = lists:append(maps:values(RecordsByName)),
                push_set_zone(ZoneName, Records)
        end, {ok, [], []}, lists:reverse(Modes)).

-spec(push_lww_zone(dns:dname(), #{dns:dname() => [dns:dns_rr()]}) -> ok).
push_lww_zone(ZoneName, RecordsByName) when is_map(RecordsByName) ->
    Op = {assign, RecordsByName, erlang:system_time(millisecond)},
    {ok, _Info} = lashup_kv:request_op(
        ?LASHUP_LWW_KEY(ZoneName),
        {update, [{update, ?RECORDS_LWW_FIELD, Op}]}),
    ok.

-spec(push_set_zone(dns:dname(), [dns:dns_rr()]) -> ok).
push_set_zone(ZoneName, Records) ->
    Key = ?LASHUP_SET_KEY(ZoneName),
    LRecords = lashup_kv:value(Key),
    LRecords0 =
        case lists:keyfind(?RECORDS_SET_FIELD, 1, LRecords) of
            false -> [];
            {_, LR} -> LR
        end,
    push_set_diff(ZoneName, Records, LRecords0).

-spec(push_set_diff(dns:dname(), [dns:dns_rr()], [dns:dns_rr()]) -> ok).
push_set_diff(ZoneName, New, Old) ->
    case dcos_net_utils:complement(New, Old) of
        {[], []} ->
            ok;
        {AddRecords, RemoveRecords} ->
            Ops = [{remove_all, RemoveRecords}, {add_all, AddRecords}],
            push_set_ops(ZoneName, Ops)
    end.

-spec(push_set_ops(dns:dname(), [riak_dt_orswot:orswot_op()]) -> ok).
push_set_ops(_ZoneName, []) ->
    ok;
push_set_ops(ZoneName, Ops) ->
    Key = ?LASHUP_SET_KEY(ZoneName),
    Updates = [{update, ?RECORDS_SET_FIELD, Op} || Op <- Ops],
    case lashup_kv:request_op(Key, {update, Updates}) of
        {ok, _} -> ok
    end.

-spec(handle_push_ops([riak_dt_orswot:orswot_op()], state()) -> state()).
handle_push_ops([], State) ->
    State;
handle_push_ops(Ops, #state{ops = [], ops_ref = undefined}=State) ->
    % NOTE: push data to lashup 1 time per second
    State0 = handle_push_zone_ops(Ops, State),
    State0#state{ops_ref = start_push_ops_timer()};
handle_push_ops(Ops, #state{ops = Buf} = State) ->
    State#state{ops = Buf ++ Ops}.

-spec(handle_push_ops(state()) -> state()).
handle_push_ops(#state{ops = Ops} = State) ->
    State0 = handle_push_zone_ops(Ops, State),
    State0#state{ops = [], ops_ref = undefined}.

-spec(handle_push_zone_ops([Op], state()) -> state()
    when Op :: riak_dt_orswot:orswot_op()).
handle_push_zone_ops(Ops, #state{records_by_name = RecordsByName} = State) ->
    ZoneName = ?DCOS_DOMAIN,
    Modes = dcos_dns_config:store_modes(),
    [ ok = push_lww_zone(ZoneName, RecordsByName) || lists:member(lww, Modes) ],
    [ ok = push_set_ops(ZoneName, Ops) || lists:member(set, Modes) ],
    State.

-spec(start_push_ops_timer() -> reference()).
start_push_ops_timer() ->
    Timeout = application:get_env(dcos_dns, push_ops_timeout, 1000),
    erlang:start_timer(Timeout, self(), push_ops).
