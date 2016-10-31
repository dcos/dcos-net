%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 12:58 PM
%%%-------------------------------------------------------------------
-module(dcos_dns_poll_server).
-author("sdhillon").

-behaviour(gen_server).

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
-define(MESOS_DNS_URI, "http://localhost:8123/v1/axfr").


%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
    handle_info/2,
    terminate/2,
    code_change/3,
    handle_call/3,
    handle_cast/2]).

-define(SERVER, ?MODULE).

-define(PROTOCOLS, [<<"_tcp">>, <<"_udp">>]).

-record(state, {}).

-type ip_resolver() :: fun((task()) -> ({Prefix :: binary(), IP :: inet:ipv4_address()})).

%%%===================================================================
%%% API
%%%===================================================================

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
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    timer:send_after(poll_period(), poll),
    {ok, #state{}}.

handle_info(poll, State) ->
    case is_leader() of
        true ->
            poll();
        false ->
            ok
    end,
    timer:send_after(poll_period(), poll),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

is_leader() ->
    {ok, IFAddrs} = inet:getifaddrs(),
    case inet:getaddr("leader.mesos", inet) of
        {ok, Addr} ->
            is_leader(IFAddrs, Addr);
        _ ->
            false
    end.

-spec(is_leader(IFAddrs :: [term()], Addr :: inet:ip4_address()) -> boolean()).
is_leader(IFAddrs, Addr) ->
    IfOpts = [IfOpt || {_IfName, IfOpt} <- IFAddrs],
    lists:any(fun(IfOpt) -> lists:member({addr, Addr}, IfOpt) end, IfOpts).

poll_period() ->
    application:get_env(dcos_dns, poll_period, 30000).

scheme() ->
    case os:getenv("MESOS_STATE_SSL_ENABLED") of
        "true" ->
            "https";
        _ ->
            "http"
    end.

%% Gotta query the leader for all the tasks
mesos_master_uri() ->
    case inet:getaddr("leader.mesos", inet) of
        {ok, _} ->
            lists:flatten(scheme() ++ "://leader.mesos:5050/state");
        _ ->
            IP = inet:ntoa(mesos_state:ip()),
            lists:flatten(io_lib:format("~s://~s:5050/state", [scheme(), IP]))
    end.

%% We should only ever poll mesos dns on the masters
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
    Headers = [],
    Response = httpc:request(get, {?MESOS_DNS_URI, Headers}, Options, [{body_format, binary}]),
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


%%
%% Tasks IPs are identified with up to three DNS A records: agentip, containerip and autoip.
%% The autoip is derived from the containerip or agentip.  The autoip is defined as matching
%% the containerip, if it is reachable.  A containerip is reachable if port mappings don't exist
%% and the containerip exists.
%%
%% Pseudo Code
%%
%% if If task.network_info.ip_address AND NOT task.port_mappings
%%     return task.networkinfo.ip_address
%% else
%%     return agent_ip
%%

-spec(task_ip_by_agent(task()) -> {binary(), inet:ip4_address()}).
task_ip_by_agent(_Task = #task{slave = #slave{pid = #libprocess_pid{ip = IP}}}) ->
    {<<"agentip">>, IP}.

-spec(task_ip_by_agent(task(), binary()) -> {binary(), inet:ip4_address()}).
task_ip_by_agent(_Task = #task{slave = #slave{pid = #libprocess_pid{ip = IP}}}, Label) ->
    {Label, IP}.

-spec(task_ip_by_network_infos(task()) -> {binary(), inet:ip4_address()}).
task_ip_by_network_infos(
    #task{statuses = [#task_status{container_status = #container_status{network_infos = NetworkInfos}}|_]}) ->
    [#network_info{ip_addresses = IPAddresses}|_] = NetworkInfos,
    [#ip_address{ip_address = IP}|_] = IPAddresses,
    {<<"containerip">>, IP}.

-spec(task_ip_by_network_infos(task(), binary()) -> {binary(), inet:ip4_address()}).
task_ip_by_network_infos(
    #task{statuses = [#task_status{container_status = #container_status{network_infos = NetworkInfos}}|_]}, Label) ->
    [#network_info{ip_addresses = IPAddresses}|_] = NetworkInfos,
    [#ip_address{ip_address = IP}|_] = IPAddresses,
    {Label, IP};
task_ip_by_network_infos(Task, Label) ->
   task_ip_by_agent(Task, Label).

-spec(task_ip_autoip(task()) -> {binary(), inet:ip4_address()}).
task_ip_autoip(Task = #task{container = #container{type = docker, docker = #docker{port_mappings = []}}}) ->
    task_ip_by_agent(Task, <<"autoip">>);
task_ip_autoip(Task) ->
    task_ip_by_network_infos(Task, <<"autoip">>).



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
    Acc2 = add_task_record(fun task_ip_by_network_infos/1, Task, Acc1),
    add_task_record(fun task_ip_autoip/1, Task, Acc2);
add_task_record(Task, Acc0) ->
    Acc1 = add_task_record(fun task_ip_by_agent/1, Task, Acc0),
    add_task_record(fun task_ip_autoip/1, Task, Acc1).

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
    JSONFilename = filename:join(DataDir, "fake.json"),
    {ok, Data} = file:read_file(JSONFilename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    {_Zone, Records} = build_zone(ParsedBody),
    RecordFileName = filename:join(DataDir, "fake_records"),
    {ok, [ExpectedRecords]} = file:consult(RecordFileName),
    ?assertEqual(ExpectedRecords, Records).

zone_records_single_agentip_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "fake.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Tasks = mesos_state_client:tasks(ParsedBody),
    [A|_T] = Tasks,
    Result = task_ip_by_agent(A),
    ExpectedResult = {<<"agentip">>, {1, 2, 3, 12}},
    ?assertEqual(ExpectedResult, Result).

zone_records_single_autoip_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "fake.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Tasks = mesos_state_client:tasks(ParsedBody),
    [A|_T] = Tasks,
    Result = task_ip_autoip(A),
    ExpectedResult = {<<"autoip">>, {1, 2, 3, 12}},
    ?assertEqual(ExpectedResult, Result).

zone_records_agentip_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "fake.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Tasks = mesos_state_client:tasks(ParsedBody),
    AgentIPList = [task_ip_by_agent(X) || X <- Tasks],
    %% ?debugFmt("Agentip List: ~p", [AgentIPList]).
    ?assertEqual(expected_agentip_list(), AgentIPList).

expected_agentip_list() ->
    [{<<"agentip">>, {1, 2, 3, 12}},
    {<<"agentip">>, {1, 2, 3, 11}},
    {<<"agentip">>, {1, 2, 3, 11}},
    {<<"agentip">>, {1, 2, 3, 11}},
    {<<"agentip">>, {1, 2, 3, 12}},
    {<<"agentip">>, {1, 2, 3, 11}},
    {<<"agentip">>, {1, 2, 3, 11}},
    {<<"agentip">>, {1, 2, 3, 11}},
    {<<"agentip">>, {1, 2, 3, 11}}].

zone_records_autoip_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "fake.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Tasks = mesos_state_client:tasks(ParsedBody),
    AutoIPList = [task_ip_autoip(X) || X <- Tasks],
    %% ?debugFmt("Autoip List: ~p", [AutoIPList]).
    ?assertEqual(expected_autoip_list(), AutoIPList).

expected_autoip_list() ->
    [{<<"autoip">>, {1, 2, 3, 12}},
    {<<"autoip">>, {1, 2, 3, 11}},
    {<<"autoip">>, {1, 2, 3, 11}},
    {<<"autoip">>, {1, 2, 3, 11}},
    {<<"autoip">>, {1, 2, 3, 12}},
    {<<"autoip">>, {1, 2, 3, 11}},
    {<<"autoip">>, {1, 2, 3, 11}},
    {<<"autoip">>, {1, 2, 3, 11}},
    {<<"autoip">>, {1, 2, 3, 11}}].

zone_records_state3_test() ->
    DataDir = code:priv_dir(dcos_dns),
    JSONFilename = filename:join(DataDir, "state3.json"),
    {ok, Data} = file:read_file(JSONFilename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    {_Zone, Records} = build_zone(ParsedBody),
    RecordFileName = filename:join(DataDir, "state3_records"),
    {ok, [ExpectedRecords]} = file:consult(RecordFileName),
    ?assertEqual(ExpectedRecords, Records).

zone_records_state5_test() ->
    DataDir = code:priv_dir(dcos_dns),
    JSONFilename = filename:join(DataDir, "state5.json"),
    {ok, Data} = file:read_file(JSONFilename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    {_Zone, Records} = build_zone(ParsedBody),
    RecordFileName = filename:join(DataDir, "state5_records"),
    {ok, [ExpectedRecords]} = file:consult(RecordFileName),
    ?assertEqual(ExpectedRecords, Records).

zone_records_state6_test() ->
    DataDir = code:priv_dir(dcos_dns),
    JSONFilename = filename:join(DataDir, "state6.json"),
    {ok, Data} = file:read_file(JSONFilename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    {_Zone, Records} = build_zone(ParsedBody),
    RecordFileName = filename:join(DataDir, "state6_records"),
    {ok, [ExpectedRecords]} = file:consult(RecordFileName),
    ?assertEqual(ExpectedRecords, Records).

zone_records_mesos_dns_test() ->
    DataDir = code:priv_dir(dcos_dns),
    JSONFilename = filename:join(DataDir, "axfr.json"),
    {ok, Data} = file:read_file(JSONFilename),
    DecodedData = jsx:decode(Data, [return_maps]),
    {ok, ?MESOS_DOMAIN, Records} =  handle_mesos_dns_body(DecodedData),
    RecordFileName = filename:join(DataDir, "axfr_records"),
    {ok, [ExpectedRecords]} = file:consult(RecordFileName),
    ?assertEqual(ExpectedRecords, Records).

is_not_leader_test() ->
    FakeIP = {255, 255, 255, 255},
    FakeIFs = [{"lo0",
        [{flags, [up, loopback, running, multicast]},
            {addr, {0, 0, 0, 0, 0, 0, 0, 1}},
            {netmask, {65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535}},
            {addr, {127, 0, 0, 1}},
            {netmask, {255, 0, 0, 0}},
            {addr, {65152, 0, 0, 0, 0, 0, 0, 1}},
            {netmask, {65535, 65535, 65535, 65535, 0, 0, 0, 0}},
            {addr, {127, 94, 0, 2}},
            {netmask, {255, 0, 0, 0}},
            {addr, {127, 94, 0, 1}},
            {netmask, {255, 0, 0, 0}}]},
        {"gif0", [{flags, [pointtopoint, multicast]}]},
        {"stf0", [{flags, []}]},
        {"en0",
            [{flags, [up, broadcast, running, multicast]},
                {hwaddr, "x1ÁÔ¾´"},
                {addr, {65152, 0, 0, 0, 31281, 49663, 65236, 48820}},
                {netmask, {65535, 65535, 65535, 65535, 0, 0, 0, 0}},
                {addr, {10, 0, 1, 2}},
                {netmask, {255, 255, 255, 0}},
                {broadaddr, {10, 0, 1, 255}},
                {addr, {9732, 21760, 25, 1277, 31281, 49663, 65236, 48820}},
                {netmask, {65535, 65535, 65535, 65535, 0, 0, 0, 0}},
                {addr, {9732, 21760, 25, 1277, 30963, 47689, 2943, 38780}},
                {netmask, {65535, 65535, 65535, 65535, 0, 0, 0, 0}}]},
        {"en1",
            [{flags, [up, broadcast, running]},
                {hwaddr, [114, 0, 2, 202, 146, 64]}]},
        {"en2",
            [{flags, [up, broadcast, running]},
                {hwaddr, [114, 0, 2, 202, 146, 65]}]},
        {"p2p0",
            [{flags, [up, broadcast, running, multicast]},
                {hwaddr, "\n1ÁÔ¾´"}]},
        {"awdl0",
            [{flags, [broadcast, multicast]},
                {hwaddr, [138, 161, 77, 222, 245, 8]}]},
        {"bridge0",
            [{flags, [up, broadcast, running, multicast]},
                {hwaddr, [122, 49, 193, 77, 95, 0]}]},
        {"vboxnet0",
            [{flags, [up, broadcast, running, multicast]},
                {hwaddr, [10, 0, 39, 0, 0, 0]},
                {addr, {33, 33, 33, 1}},
                {netmask, {255, 255, 255, 0}},
                {broadaddr, {33, 33, 33, 255}}]},
        {"vboxnet1",
            [{flags, [broadcast, multicast]}, {hwaddr, [10, 0, 39, 0, 0, 1]}]},
        {"vboxnet2",
            [{flags, [broadcast, multicast]}, {hwaddr, [10, 0, 39, 0, 0, 2]}]},
        {"vboxnet3",
            [{flags, [broadcast, multicast]}, {hwaddr, [10, 0, 39, 0, 0, 3]}]}],
    ?assertNot(is_leader(FakeIFs, FakeIP)).

is_leader_test() ->
    FakeIP = {127, 0, 0, 1},
    FakeIFs = [{"lo0",
        [{flags, [up, loopback, running, multicast]},
            {addr, {0, 0, 0, 0, 0, 0, 0, 1}},
            {netmask, {65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535}},
            {addr, {127, 0, 0, 1}},
            {netmask, {255, 0, 0, 0}},
            {addr, {65152, 0, 0, 0, 0, 0, 0, 1}},
            {netmask, {65535, 65535, 65535, 65535, 0, 0, 0, 0}},
            {addr, {127, 94, 0, 2}},
            {netmask, {255, 0, 0, 0}},
            {addr, {127, 94, 0, 1}},
            {netmask, {255, 0, 0, 0}}]},
        {"gif0", [{flags, [pointtopoint, multicast]}]},
        {"stf0", [{flags, []}]},
        {"en0",
            [{flags, [up, broadcast, running, multicast]},
                {hwaddr, "x1ÁÔ¾´"},
                {addr, {65152, 0, 0, 0, 31281, 49663, 65236, 48820}},
                {netmask, {65535, 65535, 65535, 65535, 0, 0, 0, 0}},
                {addr, {10, 0, 1, 2}},
                {netmask, {255, 255, 255, 0}},
                {broadaddr, {10, 0, 1, 255}},
                {addr, {9732, 21760, 25, 1277, 31281, 49663, 65236, 48820}},
                {netmask, {65535, 65535, 65535, 65535, 0, 0, 0, 0}},
                {addr, {9732, 21760, 25, 1277, 30963, 47689, 2943, 38780}},
                {netmask, {65535, 65535, 65535, 65535, 0, 0, 0, 0}}]},
        {"en1",
            [{flags, [up, broadcast, running]},
                {hwaddr, [114, 0, 2, 202, 146, 64]}]},
        {"en2",
            [{flags, [up, broadcast, running]},
                {hwaddr, [114, 0, 2, 202, 146, 65]}]},
        {"p2p0",
            [{flags, [up, broadcast, running, multicast]},
                {hwaddr, "\n1ÁÔ¾´"}]},
        {"awdl0",
            [{flags, [broadcast, multicast]},
                {hwaddr, [138, 161, 77, 222, 245, 8]}]},
        {"bridge0",
            [{flags, [up, broadcast, running, multicast]},
                {hwaddr, [122, 49, 193, 77, 95, 0]}]},
        {"vboxnet0",
            [{flags, [up, broadcast, running, multicast]},
                {hwaddr, [10, 0, 39, 0, 0, 0]},
                {addr, {33, 33, 33, 1}},
                {netmask, {255, 255, 255, 0}},
                {broadaddr, {33, 33, 33, 255}}]},
        {"vboxnet1",
            [{flags, [broadcast, multicast]}, {hwaddr, [10, 0, 39, 0, 0, 1]}]},
        {"vboxnet2",
            [{flags, [broadcast, multicast]}, {hwaddr, [10, 0, 39, 0, 0, 2]}]},
        {"vboxnet3",
            [{flags, [broadcast, multicast]}, {hwaddr, [10, 0, 39, 0, 0, 3]}]}],
    ?assert(is_leader(FakeIFs, FakeIP)).
-endif.
