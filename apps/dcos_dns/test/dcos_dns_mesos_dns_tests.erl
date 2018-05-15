-module(dcos_dns_mesos_dns_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("erldns/include/erldns.hrl").
-include("dcos_dns.hrl").

%%%===================================================================
%%% Tests
%%%===================================================================

basic_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"Marathon", fun marathon/0},
        {"None on Host", fun none_on_host/0},
        {"None on User", fun none_on_dcos/0},
        {"UCR on Host", fun ucr_on_host/0},
        {"UCR on Bridge", fun ucr_on_bridge/0},
        {"UCR on User", fun ucr_on_dcos/0},
        {"Docker on Host", fun docker_on_host/0},
        {"Docker on Bridge", fun docker_on_bridge/0},
        {"Docker on User", fun docker_on_dcos/0},
        {"Docker on IPv6", fun docker_on_ipv6/0},
        {"Pod on Host", fun pod_on_host/0},
        {"Pod on Bridge", fun pod_on_bridge/0},
        {"Pod on User", fun pod_on_dcos/0},
        {"Hello World", fun hello_world/0}
    ]}.

-define(LOCALHOST, {127, 0, 0, 1}).
resolve(DName) ->
    resolve(?DNS_TYPE_A, DName).

resolve(DType, DName) ->
    DNSQueries = [#dns_query{name=DName, type=DType}],
    DNSMessage = #dns_message{
        rd=true, qc=length(DNSQueries),
        questions=DNSQueries
    },
    #dns_message{answers=DNSAnswers} =
        erldns_handler:do_handle(DNSMessage, ?LOCALHOST),
    DNSAnswers.

%%%===================================================================
%%% Basic Tests
%%%===================================================================

-define(F_DNAME(Framework),
    <<Framework, ".", ?MESOS_DOMAIN/binary>>).
-define(DNAME(AppName), ?DNAME(AppName, "marathon")).
-define(DNAME(AppName, Framework), <<AppName, ".", ?F_DNAME(Framework)/binary>>).
-define(SRV_DNAME(Type, AppName), ?SRV_DNAME(Type, AppName, "marathon")).
-define(SRV_DNAME(Type, AppName, Framework),
    ?DNAME(<<"_", Type, "._", AppName, "._tcp">>/binary, Framework)).

marathon() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?F_DNAME("marathon"))).

none_on_host() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("none-on-host"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_srv{port = 31775}}],
        resolve(?DNS_TYPE_SRV, ?SRV_DNAME("http", "none-on-host"))).

none_on_dcos() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("none-on-dcos"))).

ucr_on_host() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("ucr-on-host"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_srv{port = 5463}}],
        resolve(?DNS_TYPE_SRV, ?SRV_DNAME("http", "ucr-on-host"))).

ucr_on_bridge() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 6}}}],
        resolve(?DNAME("ucr-on-bridge"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_srv{port = 18236}}],
        resolve(?DNS_TYPE_SRV, ?SRV_DNAME("http", "ucr-on-bridge"))).

ucr_on_dcos() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 6}}}],
        resolve(?DNAME("ucr-on-dcos"))).

docker_on_host() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 6}}}],
        resolve(?DNAME("docker-on-host"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_srv{port = 12018}}],
        resolve(?DNS_TYPE_SRV, ?SRV_DNAME("http", "docker-on-host"))).

docker_on_bridge() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("docker-on-bridge"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_srv{port = 23866}}],
        resolve(?DNS_TYPE_SRV, ?SRV_DNAME("http", "docker-on-bridge"))).

docker_on_dcos() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("docker-on-dcos"))).

docker_on_ipv6() ->
    {ok, IPv6} = inet:parse_ipv6_address("fd01:b::2:8000:0:2"),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_aaaa{ip = IPv6}}],
        resolve(?DNS_TYPE_AAAA, ?DNAME("docker-on-ipv6"))).

pod_on_host() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 6}}}],
        resolve(?DNAME("pod-on-host"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_srv{port = 11462}}],
        resolve(?DNS_TYPE_SRV, ?SRV_DNAME("http", "pod-on-host"))).

pod_on_bridge() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("pod-on-bridge"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_srv{port = 7699}}],
        resolve(?DNS_TYPE_SRV, ?SRV_DNAME("http", "pod-on-bridge"))).

pod_on_dcos() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("pod-on-dcos"))).

hello_world() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("hello-world"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_srv{port = 9453}}],
        resolve(?DNS_TYPE_SRV, ?SRV_DNAME("api", "hello-world"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 5}}}],
        resolve(?DNAME("world-0-server", "hello-world"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 6}}}],
        resolve(?DNAME("world-1-server", "hello-world"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 6}}}],
        resolve(?DNAME("hello-0-server", "hello-world"))).

%%%===================================================================
%%% Setup & cleanup
%%%===================================================================

setup() ->
    {ok, Cwd} = file:get_cwd(),
    DataFile = filename:join(Cwd, "apps/dcos_dns/test/axfr.json"),
    {ok, Data} = file:read_file(DataFile),

    meck:new(lashup_kv),
    meck:expect(lashup_kv, value, fun value/1),
    meck:expect(lashup_kv, request_op, fun request_op/2),

    meck:new(httpc),
    meck:expect(httpc, request,
        fun (get, Request, _HTTPOptions, _Options) ->
            Ref = make_ref(),
            {"http://127.0.0.1:8123/v1/axfr", _Headers} = Request,
            self() ! {http, {Ref, {{"HTTP/1.1", 200, "OK"}, [], Data}}},
            {ok, Ref}
        end),

    meck:new(dcos_net_mesos_listener),
    meck:expect(dcos_net_mesos_listener, is_leader, fun () -> true end),

    {ok, Apps} = ensure_all_started(erldns),
    {ok, Pid} = dcos_dns_mesos_dns:start_link(),
    true =
        lists:any(fun (_) ->
            timer:sleep(100),
            length(resolve(?F_DNAME("marathon"))) > 0
        end, lists:seq(1, 20)),

    {Pid, Apps}.

cleanup({Pid, Apps}) ->
    lists:foreach(fun application:stop/1, Apps),
    lists:foreach(fun application:unload/1, Apps),

    unlink(Pid),
    exit(Pid, kill),

    meck:unload([
        lashup_kv,
        httpc,
        dcos_net_mesos_listener
    ]).

ensure_all_started(erldns) ->
    ok = application:load(lager),
    ok = application:load(erldns),

    {ok, Cwd} = file:get_cwd(),
    SysConfigFile = filename:join(Cwd, "config/ct.sys.config"),
    {ok, [SysConfig]} = file:consult(SysConfigFile),
    lists:foreach(fun ({App, Config}) ->
        lists:foreach(fun ({K, V}) ->
            application:set_env(App, K, V)
        end, Config)
    end, SysConfig),

    application:ensure_all_started(erldns).

%%%===================================================================
%%% Lashup Mocks
%%%===================================================================

value(?LASHUP_KEY(ZoneName)) ->
    case erldns_zone_cache:get_zone_with_records(ZoneName) of
        {ok, #zone{records = Records}} ->
            [{?RECORDS_FIELD, Records}];
        {error, zone_not_found} ->
            [{?RECORDS_FIELD, []}]
    end.

request_op(LKey = ?LASHUP_KEY(ZoneName), {update, Updates}) ->
    [{?RECORDS_FIELD, Records}] = lashup_kv:value(LKey),
    Records0 = apply_op(Records, Updates),
    Sha = crypto:hash(sha, term_to_binary(Records0)),
    erldns_zone_cache:put_zone({ZoneName, Sha, Records0}),
    {ok, value(LKey)}.

apply_op(List, Updates) ->
    lists:foldl(
        fun ({update, ?RECORDS_FIELD, {remove_all, RList}}, Acc) ->
                Acc -- RList;
            ({update, ?RECORDS_FIELD, {add_all, AList}}, Acc) ->
                Acc ++ AList
        end, List, Updates).
