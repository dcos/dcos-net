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

-spec(start_link() -> {ok, pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

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

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

is_leader() ->
    {ok, IFAddrs} = inet:getifaddrs(),
    case dcos_dns:get_leader_addr() of
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
    MesosMasterIP =
        case dcos_dns:get_leader_addr() of
            {ok, IP} -> IP;
            _Error -> mesos_state:ip()
        end,
    Host = inet:ntoa(MesosMasterIP),
    lists:flatten([scheme(), "://", Host, ":5050/state"]).

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
    case inet:parse_address(IPStr) of
        {ok, IP} ->
            Record = record(RecordName1, IP),
            [Record|Acc];
        {error, Reason} ->
            lager:warning("Couldn't create DNS A record: ~p:~p Error:~p", [RecordName1, IPStr, Reason]),
            Acc
    end.

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
%% if task.port_mappings:
%%  return agent_ip
%% else:
%%  return task.networkinfo.ip_address
%%

-spec(task_ip_by_agent(task()) -> {binary(), [inet:ip4_address()]}).
task_ip_by_agent(_Task = #task{slave = #slave{pid = #libprocess_pid{ip = IP}}}) ->
    {<<"agentip">>, [IP]}.

-spec(task_ip_by_agent(task(), binary()) -> {binary(), [inet:ip4_address()]}).
task_ip_by_agent(_Task = #task{slave = #slave{pid = #libprocess_pid{ip = IP}}}, Label) ->
    {Label, [IP]}.

-spec(task_ip_by_network_infos(task()) -> {binary(), [inet:ip_address()]}).
task_ip_by_network_infos(
    #task{statuses = [#task_status{container_status = #container_status{network_infos = NetworkInfos}}|_]}) ->
    [#network_info{ip_addresses = IPAddresses}|_] = NetworkInfos,
    IPs = [IP || #ip_address{ip_address = IP} <- IPAddresses],
    {<<"containerip">>, IPs}.

-spec(task_ip_by_network_infos(task(), binary()) -> {binary(), [inet:ip_address()]}).
task_ip_by_network_infos(
    #task{statuses = [#task_status{container_status = #container_status{network_infos = NetworkInfos}}|_]}, Label) ->
    [#network_info{ip_addresses = IPAddresses}|_] = NetworkInfos,
    IPs = [IP || #ip_address{ip_address = IP} <- IPAddresses],
    {Label, IPs};
task_ip_by_network_infos(Task, Label) ->
   task_ip_by_agent(Task, Label).

-spec(task_ip_autoip(task()) -> {binary(), [inet:ip_address()]}).
task_ip_autoip(Task = #task{container = #container{type = docker, docker = #docker{port_mappings = PortMappings}}}) when
        PortMappings == [] orelse PortMappings == undefined ->
    task_ip_by_network_infos(Task, <<"autoip">>);
task_ip_autoip(Task = #task{container = #container{type = mesos, network_infos = NetworkInfos}}) when
        NetworkInfos == [] orelse NetworkInfos == undefined ->
    task_ip_autoip_other_networkInfos(Task);
task_ip_autoip(Task = #task{container = #container{type = mesos,
        network_infos = [#network_info{port_mappings = PortMappings}|_]}}) when
        PortMappings == [] orelse PortMappings == undefined ->
    task_ip_autoip_other_networkInfos(Task);
task_ip_autoip(Task) ->
    task_ip_by_agent(Task, <<"autoip">>).

task_ip_autoip_other_networkInfos(Task = #task{statuses = [#task_status{
       container_status = #container_status{network_infos = NetworkInfos}}|_]}) when
       NetworkInfos == [] orelse NetworkInfos == undefined ->
    task_ip_autoip_no_networkinfos(Task);
task_ip_autoip_other_networkInfos(Task = #task{statuses = [#task_status{
       container_status = #container_status{network_infos = [#network_info{port_mappings = PortMappings}|_]}}|_]}) when
       PortMappings == [] orelse PortMappings == undefined ->
    task_ip_by_network_infos(Task, <<"autoip">>);
task_ip_autoip_other_networkInfos(Task) ->
    task_ip_by_agent(Task, <<"autoip">>).

task_ip_autoip_no_networkinfos(Task) ->
    task_ip_by_agent(Task, <<"autoip">>).


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
    add_task_record(fun task_ip_autoip_no_networkinfos/1, Task, Acc1).

-spec(add_task_record(ip_resolver(), task(), [dns:dns_rr()]) -> [dns:dns_rr()]).
add_task_record(IPResolver, Task = #task{discovery = undefined}, Acc) ->
    #task{name = Name} = Task,
    add_task_records(Name, IPResolver, Task, Acc);
add_task_record(IPResolver, Task = #task{discovery = Discovery = #discovery{}}, Acc) ->
    #discovery{name = Name} = Discovery,
    add_task_records(Name, IPResolver, Task, Acc).

add_task_records(Name, IPResolver, Task, Acc0) when is_binary(Name) ->
    basic_task_record(Name, IPResolver, Task, Acc0).

basic_task_record(Name, IPResolver, Task = #task{framework = #framework{name = FrameworkName}}, Acc) ->
    {Postfix, IPs} = IPResolver(Task),
    FormatedName = format_name([Name, FrameworkName], Postfix),
    basic_task_record(FormatedName, IPs, Acc).

basic_task_record(_, [], Acc) ->
    Acc;
basic_task_record(FormatedName, [IP|Rest], Acc) ->
    Record = record(FormatedName, IP),
    basic_task_record(FormatedName, Rest, [Record | Acc]).

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

record(Name, IP) ->
    case dcos_dns:family(IP) of
        inet ->
            #dns_rr{
                name = Name,
                type = ?DNS_TYPE_A,
                ttl = ?TTL,
                data = #dns_rrdata_a{ip = IP}
            };
        inet6 ->
            #dns_rr{
                name = Name,
                type = ?DNS_TYPE_AAAA,
                ttl = ?TTL,
                data = #dns_rrdata_aaaa{ip = IP}
            }
    end.


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
    Ops0 = lists:foldl(fun delete_op/2, [], RecordsToDelete),
    case RecordsToAdd of
        [] ->
            Ops0;
        _ ->
            [{update, ?RECORDS_FIELD, {add_all, RecordsToAdd}}|Ops0]
    end.

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
    ExpectedResult = {<<"agentip">>, [{1, 2, 3, 12}]},
    ?assertEqual(ExpectedResult, Result).

zone_records_single_autoip_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "fake.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Tasks = mesos_state_client:tasks(ParsedBody),
    [A|_T] = Tasks,
    Result = task_ip_autoip(A),
    ExpectedResult = {<<"autoip">>, [{1, 2, 3, 12}]},
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
    [{<<"agentip">>, [{1, 2, 3, 12}]},
    {<<"agentip">>, [{1, 2, 3, 11}]},
    {<<"agentip">>, [{1, 2, 3, 11}]},
    {<<"agentip">>, [{1, 2, 3, 11}]},
    {<<"agentip">>, [{1, 2, 3, 12}]},
    {<<"agentip">>, [{1, 2, 3, 11}]},
    {<<"agentip">>, [{1, 2, 3, 11}]},
    {<<"agentip">>, [{1, 2, 3, 11}]},
    {<<"agentip">>, [{1, 2, 3, 11}]}].

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
    [{<<"autoip">>, [{1, 2, 3, 12}]},
    {<<"autoip">>, [{1, 2, 3, 11}]},
    {<<"autoip">>, [{1, 2, 3, 11}]},
    {<<"autoip">>, [{1, 2, 3, 11}]},
    {<<"autoip">>, [{1, 2, 3, 12}]},
    {<<"autoip">>, [{1, 2, 3, 11}]},
    {<<"autoip">>, [{1, 2, 3, 11}]},
    {<<"autoip">>, [{1, 2, 3, 11}]},
    {<<"autoip">>, [{1, 2, 3, 11}]}].

zone_records_ucr_autoip_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "ucr-bridge-mode-net-info.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Tasks = mesos_state_client:tasks(ParsedBody),
    [A|_T] = Tasks,
    Result = task_ip_autoip(A),
    ExpectedResult = {<<"autoip">>, [{10, 0, 2, 5}]},
    ?assertEqual(ExpectedResult, Result).

zone_records_ucr_autoip2_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "ucr-bridge-mode-no-net-info.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Tasks = mesos_state_client:tasks(ParsedBody),
    [A|_T] = Tasks,
    Result = task_ip_autoip(A),
    ExpectedResult = {<<"autoip">>, [{172, 31, 254, 2}]},
    ?assertEqual(ExpectedResult, Result).

zone_records_state_ipv6_autoip_test() ->
    DataDir = code:priv_dir(dcos_dns),
    Filename = filename:join(DataDir, "state_ipv6.json"),
    {ok, Data} = file:read_file(Filename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    Tasks = mesos_state_client:tasks(ParsedBody),
    [A|_T] = Tasks,
    Result = task_ip_autoip(A),
    ExpectedResult = {<<"autoip">>, [{16#fd01, 16#0, 16#0, 16#0, 16#0, 16#1, 16#8000, 16#4}, {12, 0, 1, 4}]},
    ?assertEqual(ExpectedResult, Result).

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

zone_records_state7_test() ->
    DataDir = code:priv_dir(dcos_dns),
    JSONFilename = filename:join(DataDir, "state7.json"),
    {ok, Data} = file:read_file(JSONFilename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    {_Zone, Records} = build_zone(ParsedBody),
    RecordFileName = filename:join(DataDir, "state7_records"),
    {ok, [ExpectedRecords]} = file:consult(RecordFileName),
    ?assertEqual(ExpectedRecords, Records).


zone_records_state8_test() ->
    DataDir = code:priv_dir(dcos_dns),
    JSONFilename = filename:join(DataDir, "state8.json"),
    {ok, Data} = file:read_file(JSONFilename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    {_Zone, Records} = build_zone(ParsedBody),
    RecordFileName = filename:join(DataDir, "state8_records"),
    {ok, [ExpectedRecords]} = file:consult(RecordFileName),
    ?assertEqual(ExpectedRecords, Records).

zone_records_state_ipv6_test() ->
    DataDir = code:priv_dir(dcos_dns),
    JSONFilename = filename:join(DataDir, "state_ipv6.json"),
    {ok, Data} = file:read_file(JSONFilename),
    {ok, ParsedBody} = mesos_state_client:parse_response(Data),
    {_Zone, Records} = build_zone(ParsedBody),
    RecordFileName = filename:join(DataDir, "state_ipv6_records"),
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

invalid_records_mesos_dns_test() ->
    DataDir = code:priv_dir(dcos_dns),
    JSONFilename = filename:join(DataDir, "axfr2.json"),
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
