-module(dcos_dns_mesos).
-behavior(dcos_net_gen_mesos_listener).

-include("dcos_dns.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("dns/include/dns.hrl").

%% API
-export([
    start_link/0,
    push_zone/2
]).

%% dcos_net_gen_mesos_listener callbacks
-export([handle_info/2, handle_reset/1, handle_push/1,
    handle_tasks/1, handle_task_updated/3]).

-type task() :: dcos_net_mesos_listener:task().
-type task_id() :: dcos_net_mesos_listener:task_id().

-record(state, {
    tasks = #{} :: #{task_id() => [dns:dns_rr()]},
    records = #{} :: #{dns:dns_rr() => pos_integer()},
    records_by_name = #{} :: #{dns:dname() => [dns:dns_rr()]},
    masters_ref = undefined :: undefined | reference(),
    masters = [] :: [dns:dns_rr()]
}).
-type state() :: #state{}.

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    dcos_net_gen_mesos_listener:start_link({local, ?MODULE}, ?MODULE).

-spec(push_zone(dns:dname(), #{dns:dname() => [dns:dns_rr()]}) -> ok).
push_zone(ZoneName, RecordsByName) when is_map(RecordsByName) ->
    Op = {assign, RecordsByName, erlang:system_time(millisecond)},
    {ok, _Info} = lashup_kv:request_op(
        ?LASHUP_LWW_KEY(ZoneName),
        {update, [{update, ?RECORDS_LWW_FIELD, Op}]}),
    ok.

%%%===================================================================
%%% dcos_net_gen_mesos_listener callbacks
%%%===================================================================

handle_info({timeout, Ref, masters}, #state{masters_ref = Ref} = State) ->
    {Updated, State0} = handle_masters(State),
    {noreply, State0, Updated};
handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_reset(#state{masters_ref = undefined}) ->
    ok;
handle_reset(#state{masters_ref = MRef}) ->
    _ = erlang:cancel_timer(MRef),
    ok.

handle_push(#state{records_by_name = RecordsByName}) ->
    ok = push_zone(?DCOS_DOMAIN, RecordsByName).

handle_tasks(MTasks) ->
    MRef = start_masters_timer(),
    {Tasks, Records, RecordsByName} = task_records(MTasks),
    ?LOG_NOTICE("DC/OS DNS Sync: ~p records", [maps:size(Records)]),
    #state{
        tasks = Tasks, records = Records,
        records_by_name = RecordsByName,
        masters_ref = MRef}.

handle_task_updated(TaskId, Task, #state{
        tasks = Tasks, records = Records,
        records_by_name = RecordsByName} = State) ->
    {Tasks0, Records0, RecordsByName0, Updated} =
        task_updated(TaskId, Task, Tasks, Records, RecordsByName),
    State0 = State#state{
        tasks = Tasks0, records = Records0,
        records_by_name = RecordsByName0},
    {Updated, State0}.

%%%===================================================================
%%% Tasks functions
%%%===================================================================

-spec(task_updated(task_id(), task(), Tasks, Records, RecordsByName) ->
    {Tasks, Records, RecordsByName, Updated}
    when Tasks :: #{task_id() => [dns:dns_rr()]},
         Records :: #{dns:dns_rr() => pos_integer()},
         RecordsByName :: #{dns:dns_rr() => pos_integer()},
         Updated :: boolean()).
task_updated(TaskId, Task, Tasks, Records, RecordsByName) ->
    TaskState = maps:get(state, Task),
    case {is_running(TaskState), maps:is_key(TaskId, Tasks)} of
        {Same, Same} ->
            {Tasks, Records, RecordsByName, false};
        {false, true} ->
            {TaskRRs, Tasks0} = maps:take(TaskId, Tasks),
            Records0 = update_records(TaskRRs, -1, Records),
            % Remove records if there is no another task with such records
            TaskRRs0 = [RR || RR <- TaskRRs, not maps:is_key(RR, Records0)],
            {Removed, RecordsByName0} =
                remove_from_index(TaskRRs0, RecordsByName),
            {Tasks0, Records0, RecordsByName0, Removed};
        {true, false} ->
            TaskRRs = task_records(TaskId, Task),
            Tasks0 = maps:put(TaskId, TaskRRs, Tasks),
            Records0 = update_records(TaskRRs, 1, Records),
            % Add only new records that are not in `Records` before
            TaskRRs0 = [RR || RR <- TaskRRs, not maps:is_key(RR, Records)],
            {Added, RecordsByName0} = add_to_index(TaskRRs0, RecordsByName),
            {Tasks0, Records0, RecordsByName0, Added}
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
    {_Added, InitRecordsByName} =
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
            {_Added, RecordsByName0} = add_to_index(TaskRRs0, RecordsByName),
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

-spec(add_to_index(RRs, RecordsByName) -> {boolean(), RecordsByName}
    when RRs :: [dns:dns_rr()], RecordsByName :: #{dns:dname() => RRs}).
add_to_index([], RecordsByName) ->
    {false, RecordsByName};
add_to_index(RRs, RecordsByName) ->
    lists:foldl(fun (#dns_rr{name = Name} = RR, {_Up, Acc}) ->
        {true, Acc#{Name => [RR | maps:get(Name, Acc, [])]}}
    end, {false, RecordsByName}, RRs).

-spec(remove_from_index(RRs, RecordsByName) -> {boolean(), RecordsByName}
    when RRs :: [dns:dns_rr()], RecordsByName :: #{dns:dname() => RRs}).
remove_from_index([], RecordsByName) ->
    {false, RecordsByName};
remove_from_index(RRs, RecordsByName) ->
    lists:foldl(fun (#dns_rr{name = Name} = RR, {Removed, Acc}) ->
        RRs0 = maps:get(Name, Acc),
        Acc0 = Acc#{Name => lists:delete(RR, RRs0)},
        {Removed orelse lists:member(RR, RRs0), Acc0}
    end, {false, RecordsByName}, RRs).

%%%===================================================================
%%% Masters functions
%%%===================================================================

-spec(handle_masters(state()) -> {Updated :: boolean(), state()}).
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

    {Added, RecordsByName0} = add_to_index(NewRRs, RecordsByName),
    {Removed, RecordsByName1} = remove_from_index(OldRRs, RecordsByName0),
    State0 = State#state{
        masters = MRRs0,
        masters_ref = start_masters_timer(),
        records_by_name = RecordsByName1},
    {Added orelse Removed, State0}.

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
