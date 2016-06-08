%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 12:58 PM
%%%-------------------------------------------------------------------
-module(dcos_dns_poll_fsm).
-author("sdhillon").

-behaviour(gen_fsm).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).
-endif.

-include("dcos_dns.hrl").
-include_lib("mesos_state/include/mesos_state.hrl").
-include_lib("dns/include/dns.hrl").
-define(DCOS_DOMAIN, <<"dcos.thisdcos.directory">>).
-define(MESOS_DOMAIN, <<"mesos.thisdcos.directory">>).
-define(TTL, 5).


%% API
-export([start_link/0, status/0]).

%% gen_fsm callbacks
-export([init/1,
    leader/2,
    leader/3,
    not_leader/2,
    not_leader/3,
    handle_event/3,
    handle_sync_event/4,
    handle_info/3,
    terminate/3,
    code_change/4]).

-define(SERVER, ?MODULE).

-define(MAX_CONSECUTIVE_POLLS, 10).
-define(PROTOCOLS, [<<"_tcp">>, <<"_udp">>]).

-record(state, {
    master_list = [] :: [node()],
    consecutive_polls = 0 :: non_neg_integer()
}).

-type ip_resolver() :: fun((task()) -> ({Prefix :: binary(), IP :: inet:ipv4_address()})).

%%%===================================================================
%%% API
%%%===================================================================

status() ->
    gen_fsm:sync_send_all_state_event(?SERVER, status).

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() -> {ok, pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, StateName :: atom(), StateData :: #state{}} |
    {ok, StateName :: atom(), StateData :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    gen_fsm:start_timer(master_period(), try_master),
    gen_fsm:start_timer(poll_period(), poll),
    {ok, not_leader, #state{}}.


%% See if I can become master
not_leader({timeout, _Ref, poll}, State) ->
    gen_fsm:start_timer(poll_period(), poll),
    {next_state, not_leader, State};
not_leader({timeout, _Ref, try_master}, State0) ->
    {NextStateName, State1} = try_master(State0),
    gen_fsm:start_timer(master_period(), try_master),
    {next_state, NextStateName, State1}.


not_leader(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, not_leader, State}.

%% Step down from being master, but try to get it back immediately.
%% There are situations when global can become inconsistent
leader({timeout, _Ref, try_master}, State0 = #state{consecutive_polls = CP, master_list = ML})
        when CP > ?MAX_CONSECUTIVE_POLLS ->
    gen_fsm:start_timer(1, try_master),
    global:del_lock({?MODULE, self()}, ML),
    State1 = State0#state{consecutive_polls = 0},
    {next_state, not_leader, State1};
leader({timeout, _Ref, try_master}, State0 = #state{master_list = MasterList0}) ->
    gen_fsm:start_timer(master_period(), try_master),
    case dcos_dns:masters() of
        MasterList0 ->
            {next_state, leader, State0};
        NewMasterList ->
            global:del_lock({?MODULE, self()}, MasterList0),
            State1 = State0#state{master_list = NewMasterList},
            {next_state, not_leader, State1}
    end;

leader({timeout, _Ref, poll}, State0 = #state{consecutive_polls = CP, master_list = MasterList0}) ->
    State1 = State0#state{consecutive_polls = CP + 1},
    Rep =
        case poll() of
            ok ->
                {next_state, leader, State1};
            {error, _} ->
                global:del_lock({?MODULE, self()}, MasterList0),
                {next_state, not_leader, State1}
        end,
    gen_fsm:start_timer(poll_period(), poll),
    Rep.


leader(_Event, _From, State) ->
    Reply = ok,
    {reply, Reply, not_leader, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_event(Event :: term(), StateName :: atom(),
    StateData :: #state{}) ->
    {next_state, NextStateName :: atom(), NewStateData :: #state{}} |
    {next_state, NextStateName :: atom(), NewStateData :: #state{},
        timeout() | hibernate} |
    {stop, Reason :: term(), NewStateData :: #state{}}).
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_sync_event(Event :: term(), From :: {pid(), Tag :: term()},
    StateName :: atom(), StateData :: term()) ->
    {reply, Reply :: term(), NextStateName :: atom(), NewStateData :: term()} |
    {reply, Reply :: term(), NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {next_state, NextStateName :: atom(), NewStateData :: term()} |
    {next_state, NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewStateData :: term()} |
    {stop, Reason :: term(), NewStateData :: term()}).

handle_sync_event(status, _From, StateName, State = #state{master_list = ML, consecutive_polls = CPs}) ->
    Status = #{
        state => StateName,
        masters => ML,
        poll_count => CPs
    },
    {reply, {ok, Status}, StateName, State};
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: term(), StateName :: atom(),
    StateData :: term()) ->
    {next_state, NextStateName :: atom(), NewStateData :: term()} |
    {next_state, NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {stop, Reason :: normal | term(), NewStateData :: term()}).
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: normal | shutdown | {shutdown, term()}
| term(), StateName :: atom(), StateData :: term()) -> term()).
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, StateName :: atom(),
    StateData :: #state{}, Extra :: term()) ->
    {ok, NextStateName :: atom(), NewStateData :: #state{}}).
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

poll_period() ->
    application:get_env(dcos_dns, poll_period, 30000).

master_period() ->
    application:get_env(dcos_dns, master_period, 15000).



%% Should only be called in not_leader
try_master(State0) ->
    Masters = dcos_dns:masters(),
    State1 = State0#state{master_list = Masters},
    case dcos_dns:is_master() of
        true ->
            try_master1(State1);
        false ->
            {not_leader, State1}
    end.

try_master1(State = #state{master_list = Masters}) ->
    ExemptNodes0 = application:get_env(lashup, exempt_nodes, []),
    ExemptNodes1 = lists:usort(ExemptNodes0 ++ Masters),
    application:set_env(lashup, exempt_nodes, ExemptNodes1),
    %% The reason we don't immediately return is we want to schedule the try_master event
    %% But, we must wait for it to return from global, otherwise we can get into a tight loop
    LockResult = global:set_lock({?MODULE, self()}, Masters, 1),
    case LockResult of
        true ->
            {leader, State};
        false ->
            {not_leader, State}
    end.

mesos_master_uri() ->
    case inet:getaddr("leader.mesos", inet) of
        {ok, _} ->
            "http://leader.mesos:5050/state";
        _ ->
            IP = inet:ntoa(mesos_state:ip()),
            lists:flatten(io_lib:format("http://~s:5050/state", [IP]))
    end.

mesos_dns_uri() ->
    case inet:getaddr("master.mesos", inet) of
        {ok, _} ->
            "http://master.mesos:8123/v1/axfr";
        _ ->
            IP = inet:ntoa(mesos_state:ip()),
            lists:flatten(io_lib:format("http://~s:8123/v1/axfr", [IP]))
    end.


poll() ->
    lager:info("Navstar DNS polling"),
    case mesos_master_poll() of
        ok ->
            mesos_dns_poll();
        Ret = {error, _} ->
            Ret
    end.

mesos_dns_poll() ->
    Options = [
        {timeout, application:get_env(?APP, timeout, ?DEFAULT_TIMEOUT)},
        {connect_timeout, application:get_env(?APP, connect_timeout, ?DEFAULT_CONNECT_TIMEOUT)}
    ],
    URI = mesos_dns_uri(),
    Headers = [],
    Response = httpc:request(get, {URI, Headers}, Options, [{body_format, binary}]),
    case handle_mesos_dns_response(Response) of
        {error, Reason} ->
            lager:warning("Unable to poll mesos-dns: ~p", [Reason]),
            {error, Reason};
        {ok, ZoneName, Records} ->
            ok = push_zone(ZoneName, Records),
            ok
    end.

handle_mesos_dns_response({error, Reason}) ->
    {error, Reason};
handle_mesos_dns_response({ok, {_StatusLine = {_HTTPVersion, 200 = _StatusCode, _ReasonPhrase}, _Headers, Body}}) ->
    DecodedBody = jsx:decode(Body, [return_maps]),
    handle_mesos_dns_body(DecodedBody);
handle_mesos_dns_response({ok, {StatusLine, _Headers, _Body}}) ->
    {error, StatusLine}.

handle_mesos_dns_body(_Body = #{<<"Domain">> := Domain0, <<"Records">> := MesosDNSRecords}) ->
    %% We don't want to use atoms here because the records are awkward
    Domain1 = <<Domain0/binary, ".">>,
    Records0 = base_records(?MESOS_DOMAIN),
    #{<<"As">> := ARecords, <<"SRVs">> := SRVRecords} = MesosDNSRecords,
    Records1 = maps:fold(fun(RecordName, Values, Acc) ->
        add_mesos_dns_a_recs(RecordName, Values, Domain1, Acc) end, Records0, ARecords),
    Records2 = maps:fold(fun(RecordName, Values, Acc) ->
        add_mesos_dns_srv_recs(RecordName, Values, Domain1, Acc) end, Records1, SRVRecords),
    Records3 = lists:usort(Records2),
    {ok, ?MESOS_DOMAIN, Records3}.

chop_name(RecordName0, DomainName) ->
    DomainNameSize = size(DomainName),
    binary:part(RecordName0, 0, size(RecordName0) - DomainNameSize).

add_mesos_dns_a_recs(RecordName0, Values, MesosDNSDomain, Acc) ->
    RecordName1 = chop_name(RecordName0, MesosDNSDomain),
    lists:foldl(fun(X, SubAcc) -> add_mesos_dns_a_rec(X, RecordName1, SubAcc) end, Acc, Values).

add_mesos_dns_a_rec(IPBin, RecordName0, Acc) ->
    RecordName1 = <<RecordName0/binary, ?MESOS_DOMAIN/binary>>,
    IPStr = binary_to_list(IPBin),
    {ok, IP} = inet:parse_ipv4_address(IPStr),
    Record =
        #dns_rr{
            name = RecordName1,
            type = ?DNS_TYPE_A,
            ttl = ?TTL,
            data = #dns_rrdata_a{ip = IP}
        },
    [Record|Acc].


add_mesos_dns_srv_recs(RecordName0, Values, MesosDNSDomain, Acc) ->
    RecordName1 = chop_name(RecordName0, MesosDNSDomain),
    lists:foldl(fun(X, SubAcc) -> add_mesos_dns_srv_rec(X, RecordName1, MesosDNSDomain, SubAcc) end, Acc, Values).

add_mesos_dns_srv_rec(SRV, RecordName0, MesosDNSDomain, Acc) ->
    RecordName1 = <<RecordName0/binary, ?MESOS_DOMAIN/binary>>,
    [SRVTarget0, SRVPort0] = binary:split(SRV, <<":">>),
    SRVPort1 = binary_to_integer(SRVPort0),
    SRVTarget1 = chop_name(SRVTarget0, MesosDNSDomain),
    SRVTarget2 = <<SRVTarget1/binary, ?MESOS_DOMAIN/binary>>,
    Record =
        #dns_rr{
            name = RecordName1,
            type = ?DNS_TYPE_SRV,
            ttl = ?TTL,
            data = #dns_rrdata_srv{
                target = SRVTarget2,
                port = SRVPort1,
                weight = 0,
                priority = 0
            }
        },
    [Record|Acc].

mesos_master_poll() ->
    URI = mesos_master_uri(),
    case mesos_state_client:poll(URI) of
        {ok, MAS0} ->
            {ZoneName, Records} = build_zone(MAS0),
            ok = push_zone(ZoneName, Records),
            ok;
        Error ->
            lager:warning("Could not poll mesos state: ~p", [Error]),
            {error, Error}
    end.


-spec(task_ip_by_agent(task()) -> {binary(), inet:ip4_address()}).
task_ip_by_agent(_Task = #task{slave = #slave{pid = #libprocess_pid{ip = IP}}}) ->
    {<<"agentip">>, IP}.

-spec(task_ip_by_network_infos(task()) -> {binary(), inet:ip4_address()}).
task_ip_by_network_infos(
    #task{statuses = [#task_status{container_status = #container_status{network_infos = NetworkInfos}}|_]}) ->
    [#network_info{ip_addresses = IPAddresses}|_] = NetworkInfos,
    [#ip_address{ip_address = IP}|_] = IPAddresses,
    {<<"containerip">>, IP}.

%% Creates the zone:
%% .mesos.thisdcos.directory
%% With ip sources based on (.containerip/.agentip).mesos.thisdcos.directory
build_zone(MAS) ->
    Records0 = lists:usort(add_task_records(MAS, [])),
    Records1 = ordsets:union(Records0, base_records(?DCOS_DOMAIN)),
    {?DCOS_DOMAIN, Records1}.

-spec(add_task_records(mesos_state_client:mesos_agent_state(), [dns:dns_rr()]) -> [dns:dns_rr()]).
add_task_records(MAS, Records0) ->
    Tasks = mesos_state_client:tasks(MAS),
    lists:foldl(
        fun add_task_record/2,
        Records0,
        Tasks
    ).

-spec(add_task_record(task(), [dns:dns_rr()]) -> [dns:dns_rr()]).
add_task_record(_Task = #task{state = TaskState}, Acc0) when TaskState =/= running->
    Acc0;
add_task_record(Task =
        #task{statuses = [#task_status{container_status = #container_status{network_infos = NetworkInfos}}|_]}, Acc0)
        when is_list(NetworkInfos) ->

    Acc1 = add_task_record(fun task_ip_by_agent/1, Task, Acc0),
    add_task_record(fun task_ip_by_network_infos/1, Task, Acc1);
add_task_record(Task, Acc0) ->
    add_task_record(fun task_ip_by_agent/1, Task, Acc0).


-spec(add_task_record(ip_resolver(), task(), [dns:dns_rr()]) -> [dns:dns_rr()]).
add_task_record(IPResolver, Task = #task{discovery = undefined}, Acc) ->
    #task{name = Name} = Task,
    add_task_records(Name, IPResolver, Task, Acc);
add_task_record(IPResolver, Task = #task{discovery = Discovery = #discovery{}}, Acc) ->
    #discovery{name = Name} = Discovery,
    add_task_records(Name, IPResolver, Task, Acc).

add_task_records(Name, IPResolver, Task, Acc0) when is_binary(Name) ->
    Acc1 = canonical_task_records(Name, IPResolver, Task, Acc0),
    Acc2 = slave_task_record(Name, Task, Acc1),
    basic_task_record(Name, IPResolver, Task, Acc2).

slave_task_record(Name, Task = #task{framework = #framework{name = FrameworkName}}, Acc) ->
    {_, IP} = task_ip_by_agent(Task),
    Record =
        #dns_rr{
        name = format_name([Name, FrameworkName], <<"slave">>),
        type = ?DNS_TYPE_A,
        ttl = ?TTL,
        data = #dns_rrdata_a{ip = IP}

    },
    [Record|Acc].

basic_task_record(Name, IPResolver, Task = #task{framework = #framework{name = FrameworkName}}, Acc) ->
    {Postfix, IP} = IPResolver(Task),
    Record =
        #dns_rr{
            name = format_name([Name, FrameworkName], Postfix),
            type = ?DNS_TYPE_A,
            ttl = ?TTL,
            data = #dns_rrdata_a{ip = IP}
        },
    [Record | Acc].


canonical_task_records(Name, IPResolver, Task, Acc0) ->
    #task{
        framework = #framework{
            name = FrameworkName
        }, id = TaskID0,
        slave = #slave{
            slave_id = SlaveID0
        }
    } = Task,
    {Postfix, IP} = IPResolver(Task),
    SlaveIDParts = binary:split(SlaveID0, <<"-">>, [global]),
    SlaveID1 = lists:nth(length(SlaveIDParts), SlaveIDParts),
    TaskID1 = hash_string(TaskID0),

    Canonical = <<Name/binary, <<"-">>/binary, TaskID1/binary, <<"-">>/binary, SlaveID1/binary>>,
    CanonicalFQDN = format_name([Canonical, FrameworkName], Postfix),

    %_liquor-store._tcp.marathon.mesos.  -> ip + ports
    %_liquor-store._tcp.marathon.$POSTIFX.mesos.$DOMAIN -> ip + ports
    % every protocol + port combination

    Record =
        #dns_rr{
            name = CanonicalFQDN,
            type = ?DNS_TYPE_A,
            ttl = ?TTL,
            data = #dns_rrdata_a{ip = IP}
        },
    Acc1 = [Record|Acc0],
    Acc2 = maybe_port_records(Name, Postfix, CanonicalFQDN, Task, Acc1),
    maybe_discover_info_records(Postfix, CanonicalFQDN, Task, Acc2).


maybe_discover_info_records(Postfix, CanonicalFQDN, Task = #task{discovery = Discovery = #discovery{}}, Acc0) ->
    #discovery{ports = DiscoveryPorts, name = DiscoveryName} = Discovery,
    #task{
        framework = #framework{
            name = FrameworkName
        }
    } = Task,
    %_big-dog._tcp.marathon.mesos. -- all the discoveryports for that given name
    %_https._liquor-store._tcp.marathon.mesos. -- all the discoveryports for that given port + name
    SafeFrameworkName = list_to_binary(mesos_state:label(FrameworkName)),
    SafeDiscoveryName = make_srv_like(DiscoveryName),
    PortlessRecords = [
        #dns_rr{
            name = format_name2([SafeDiscoveryName, Protocol, SafeFrameworkName, Postfix]),
            type = ?DNS_TYPE_SRV,
            ttl = ?TTL,
            data = #dns_rrdata_srv{
                priority = 10,
                weight = 10,
                port = PortNumber,
                target = CanonicalFQDN
            }
        }
        || Protocol <- ?PROTOCOLS, #mesos_port{number = PortNumber} <- DiscoveryPorts],
    PortedRecords = [
        #dns_rr{
            name = format_name2([make_srv_like(PortName), SafeDiscoveryName, make_srv_like(Protocol),
                SafeFrameworkName, Postfix]),
            type = ?DNS_TYPE_SRV,
            ttl = ?TTL,
            data = #dns_rrdata_srv{
                priority = 10,
                weight = 10,
                port = PortNumber,
                target = CanonicalFQDN
            }
        }
        || #mesos_port{name = PortName, number = PortNumber, protocol = Protocol} <- DiscoveryPorts],
    PortlessRecords ++ PortedRecords ++ Acc0;
maybe_discover_info_records(_Postfix, _CanonicalFQDN, _Task, Acc0) ->
    Acc0.


maybe_port_records(Name, Postfix, CanonicalFQDN,
    _Task = #task{
        framework = #framework{
            name = FrameworkName
        },
        resources = #{ports := Ports}
    }, Acc0) ->
    SafeName = make_srv_like(Name),
    SafeFrameworkName = list_to_binary(mesos_state:label(FrameworkName)),
    Records = [
        #dns_rr{
            name = format_name2([SafeName, Protocol, SafeFrameworkName, Postfix]),
            type = ?DNS_TYPE_SRV,
            ttl = ?TTL,
            data = #dns_rrdata_srv{
                priority = 10,
                weight = 10,
                port = Port,
                target = CanonicalFQDN
            }
        }
        || Protocol <- ?PROTOCOLS, Port <- Ports],
    Records ++ Acc0;

maybe_port_records(_Name, _Postfix, _CanonicalFQDN, _Task, Acc0) ->
    Acc0.

hash_string(String) ->
    SHA1 = crypto:hash(sha, String),
    <<Ret:5/binary, _/binary>> = zbase32:encode(SHA1),
    Ret.

make_srv_like(Name0) when is_atom(Name0) ->
    make_srv_like(atom_to_binary(Name0, utf8));
make_srv_like(Name0) ->
    Name1 = list_to_binary(mesos_state:label(Name0)),
    <<"_", Name1/binary>>.

format_name(ListOfNames0, Postfix) ->
    ListOfNames1 = lists:map(fun mesos_state:label/1, ListOfNames0),
    ListOfNames2 = lists:map(fun list_to_binary/1, ListOfNames1),
    Init = <<Postfix/binary, ".", ?DCOS_DOMAIN/binary>>,
    lists:foldr(
        fun(Part, Acc) ->
            <<Part/binary, ".", Acc/binary>>
        end,
        Init,
        ListOfNames2
    ).
format_name2(ListOfNames) ->
    lists:foldr(
        fun(Part, Acc) ->
            <<Part/binary, ".", Acc/binary>>
        end,
        ?DCOS_DOMAIN,
        ListOfNames
    ).

base_records(ZoneName) ->
    ordsets:from_list(
    [
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_SOA,
            ttl = 3600,
            data = #dns_rrdata_soa{
                mname = <<"ns.spartan">>, %% Nameserver
                rname = <<"support.mesosphere.com">>,
                serial = 1,
                refresh = 60,
                retry = 180,
                expire = 86400,
                minimum = 1
            }
        },
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ]).

ops(OldRecords, NewRecords) ->
    RecordsToDelete = ordsets:subtract(OldRecords, NewRecords),
    RecordsToAdd = ordsets:subtract(NewRecords, OldRecords),
    Ops0 = [],
    Ops1 = lists:foldl(fun delete_op/2, Ops0, RecordsToDelete),
    lists:foldl(fun add_op/2, Ops1, RecordsToAdd).

push_zone(ZoneName, NewRecords) ->
    push_zone_to_lashup(ZoneName, NewRecords),
    dcos_dns_world:push_zone_to_world(ZoneName, NewRecords),
    ok.
push_zone_to_lashup(ZoneName, NewRecords) ->
    Key = [navstar, dns, zones, ZoneName],
    {OriginalMap, VClock} = lashup_kv:value2(Key),
    OldRecords =
        case lists:keyfind(?RECORDS_FIELD, 1, OriginalMap) of
            false ->
                [];
            {_, Value} ->
                lists:usort(Value)
        end,
    Result =
        case ops(OldRecords, NewRecords) of
            [] ->
                {ok, no_change};
            Ops ->
                lashup_kv:request_op(Key, VClock, {update, Ops})
        end,
    case Result of
        {error, concurrency} ->
            ok;
        {ok, _} ->
            ok
    end.
delete_op(Record, Acc0) ->
    Op = {update, ?RECORDS_FIELD, {remove, Record}},
    [Op|Acc0].
add_op(Record, Acc0) ->
    Op = {update, ?RECORDS_FIELD, {add, Record}},
    [Op|Acc0].


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

zone_records_fake_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "fake.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Zone = dcos_dns_poll_fsm:build_zone(ParsedBody),
    ?debugFmt("Zone: ~p", [Zone]).


zone_records_state3_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "state3.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Zone = dcos_dns_poll_fsm:build_zone(ParsedBody),
    ?debugFmt("Zone: ~p", [Zone]).

zone_records_mesos_dns_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "axfr.json"),
    {ok, Data} = file:read_file(Filename),
    DecodedData = jsx:decode(Data, [return_maps]),
    {ok, ?MESOS_DOMAIN, Records} =  handle_mesos_dns_body(DecodedData),
    ExpectedRecords =
        [{dns_rr,<<"_framework._tcp.marathon.mesos.thisdcos.directory">>,1,
            33,5,
            {dns_rrdata_srv,0,0,36241,
                <<"marathon.mesos.thisdcos.directory">>}},
            {dns_rr,<<"_leader._tcp.mesos.thisdcos.directory">>,1,33,5,
                {dns_rrdata_srv,0,0,5050,
                    <<"leader.mesos.thisdcos.directory">>}},
            {dns_rr,<<"_leader._udp.mesos.thisdcos.directory">>,1,33,5,
                {dns_rrdata_srv,0,0,5050,
                    <<"leader.mesos.thisdcos.directory">>}},
            {dns_rr,<<"_slave._tcp.mesos.thisdcos.directory">>,1,33,5,
                {dns_rrdata_srv,0,0,5051,
                    <<"slave.mesos.thisdcos.directory">>}},
            {dns_rr,<<"leader.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{10,0,6,47}}},
            {dns_rr,<<"marathon.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{10,0,6,47}}},
            {dns_rr,<<"master.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{10,0,6,47}}},
            {dns_rr,<<"master0.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{10,0,6,47}}},
            {dns_rr,<<"mesos.thisdcos.directory">>,1,2,3600,
                {dns_rrdata_ns,<<"ns.spartan">>}},
            {dns_rr,<<"mesos.thisdcos.directory">>,1,6,3600,
                {dns_rrdata_soa,<<"ns.spartan">>,
                    <<"support.mesosphere.com">>,1,60,180,86400,
                    1}},
            {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{10,0,6,47}}},
            {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{172,17,0,1}}},
            {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{198,51,100,1}}},
            {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{198,51,100,2}}},
            {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{198,51,100,3}}},
            {dns_rr,<<"slave.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{10,0,3,101}}},
            {dns_rr,<<"slave.mesos.thisdcos.directory">>,1,1,5,
                {dns_rrdata_a,{10,0,5,155}}}],
    ?assertEqual(ExpectedRecords, Records).
-endif.