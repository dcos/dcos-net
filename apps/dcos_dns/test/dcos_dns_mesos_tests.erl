-module(dcos_dns_mesos_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("erldns/include/erldns.hrl").
-include("dcos_dns.hrl").

-define(
    REPEAT(Attempts, Delay, Expr),
    lists:foldl(
        fun (A, false) ->
                try (Expr),
                    true
                catch _:_ when A < Attempts ->
                    timer:sleep(Delay),
                    false
                end;
            (_A, true) ->
                true
        end, false, lists:seq(1, Attempts))).

%%%===================================================================
%%% Tests
%%%===================================================================

basic_test_() ->
    {setup, fun basic_setup/0, fun cleanup/1, [
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
        {"Pod on User", fun pod_on_dcos/0}
    ]}.

updates_test_() ->
    {setup, fun basic_setup/0, fun cleanup/1, [
        {"Add task", fun add_task/0},
        {"Remove task", fun remove_task/0}
    ]}.

hello_overlay_test_() ->
    {setup, fun hello_overlay_setup/0, fun cleanup/1, [
        {"hello-world", fun hello_overlay_world/0},
        {"hello-overlay-0-server", fun hello_overlay_server/0},
        {"hello-overlay-vip-0-server", fun hello_overlay_vip/0},
        {"hello-host-vip-0-server", fun hello_overlay_host_vip/0}
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

-define(DNAME(AppName, Type), ?DNAME(AppName, "marathon", Type)).
-define(DNAME(AppName, Framework, Type),
    <<AppName, ".", Framework, ".", Type, ".dcos.thisdcos.directory">>).

none_on_host() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("none-on-host", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("none-on-host", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("none-on-host", "containerip"))).

none_on_dcos() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("none-on-dcos", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 5}}}],
        resolve(?DNAME("none-on-dcos", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 5}}}],
        resolve(?DNAME("none-on-dcos", "containerip"))).

ucr_on_host() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("ucr-on-host", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("ucr-on-host", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("ucr-on-host", "containerip"))).

ucr_on_bridge() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("ucr-on-bridge", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("ucr-on-bridge", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 31, 254, 3}}}],
        resolve(?DNAME("ucr-on-bridge", "containerip"))).

ucr_on_dcos() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("ucr-on-dcos", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 1, 6}}}],
        resolve(?DNAME("ucr-on-dcos", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 1, 6}}}],
        resolve(?DNAME("ucr-on-dcos", "containerip"))).

docker_on_host() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("docker-on-host", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("docker-on-host", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("docker-on-host", "containerip"))).

docker_on_bridge() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("docker-on-bridge", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("docker-on-bridge", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 18, 0, 2}}}],
        resolve(?DNAME("docker-on-bridge", "containerip"))).

docker_on_dcos() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("docker-on-dcos", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 130}}}],
        resolve(?DNAME("docker-on-dcos", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 130}}}],
        resolve(?DNAME("docker-on-dcos", "containerip"))).

docker_on_ipv6() ->
    {ok, IPv6} = inet:parse_ipv6_address("fd01:b::2:8000:0:2"),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("docker-on-ipv6", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_aaaa{ip = IPv6}}],
        resolve(?DNS_TYPE_AAAA, ?DNAME("docker-on-ipv6", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_aaaa{ip = IPv6}}],
        resolve(?DNS_TYPE_AAAA, ?DNAME("docker-on-ipv6", "containerip"))).

pod_on_host() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("pod-on-host", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("pod-on-host", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("pod-on-host", "containerip"))).

pod_on_bridge() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("pod-on-bridge", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("pod-on-bridge", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 31, 254, 4}}}],
        resolve(?DNAME("pod-on-bridge", "containerip"))).

pod_on_dcos() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 3}}}],
        resolve(?DNAME("pod-on-dcos", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 1, 3}}}],
        resolve(?DNAME("pod-on-dcos", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 1, 3}}}],
        resolve(?DNAME("pod-on-dcos", "containerip"))).

%%%===================================================================
%%% Updates Tests
%%%===================================================================

add_task() ->
    State = recon:get_state(dcos_dns_mesos),
    Ref = element(2, State),
    TaskId = <<"ucr-on-dcos.4014ba90-28b2-11e8-ab5a-70b3d5800002">>,
    Task = #{
        name => <<"ucr-on-dcos">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{9, 0, 2, 3}],
        ports => [
            #{name => <<"default">>, protocol => tcp, port => 0}
        ],
        state => {running, true}
    },
    dcos_dns_mesos ! {task_updated, Ref, TaskId, Task},
    ?REPEAT(20, 100, begin
        ?assertMatch(
            [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
            resolve(?DNAME("docker-on-dcos", "agentip"))),
        ?assertMatch(
            [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 130}}}],
            resolve(?DNAME("docker-on-dcos", "autoip"))),
        ?assertMatch(
            [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 130}}}],
            resolve(?DNAME("docker-on-dcos", "containerip")))
    end).

remove_task() ->
    State = recon:get_state(dcos_dns_mesos),
    Ref = element(2, State),
    TaskId = <<"ucr-on-dcos.4014ba90-28b2-11e8-ab5a-70b3d5800002">>,
    Task = #{
        name => <<"ucr-on-dcos">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 18, 0, 5}],
        ports => [
            #{name => <<"default">>, protocol => tcp, port => 0}
        ],
        state => false
    },
    dcos_dns_mesos ! {task_updated, Ref, TaskId, Task},
    timer:sleep(1100), % 1 second buffer + delay
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {172, 17, 0, 4}}}],
        resolve(?DNAME("docker-on-dcos", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 130}}}],
        resolve(?DNAME("docker-on-dcos", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 130}}}],
        resolve(?DNAME("docker-on-dcos", "containerip"))).

%%%===================================================================
%%% Overlay Tests
%%%===================================================================

hello_overlay_world() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {10, 0, 0, 49}}}],
        resolve(?DNAME("hello-world", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {10, 0, 0, 49}}}],
        resolve(?DNAME("hello-world", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {10, 0, 0, 49}}}],
        resolve(?DNAME("hello-world", "containerip"))).

hello_overlay_server() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {10, 0, 0, 49}}}],
        resolve(?DNAME("hello-overlay-0-server",
                       "hello-world", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 2}}}],
        resolve(?DNAME("hello-overlay-0-server",
                       "hello-world", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 2}}}],
        resolve(?DNAME("hello-overlay-0-server",
                       "hello-world", "containerip"))).

hello_overlay_vip() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {10, 0, 0, 49}}}],
        resolve(?DNAME("hello-overlay-vip-0-server",
                       "hello-world", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 3}}}],
        resolve(?DNAME("hello-overlay-vip-0-server",
                       "hello-world", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {9, 0, 2, 3}}}],
        resolve(?DNAME("hello-overlay-vip-0-server",
                       "hello-world", "containerip"))).

hello_overlay_host_vip() ->
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {10, 0, 0, 49}}}],
        resolve(?DNAME("hello-host-vip-0-server",
                       "hello-world", "agentip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {10, 0, 0, 49}}}],
        resolve(?DNAME("hello-host-vip-0-server",
                       "hello-world", "autoip"))),
    ?assertMatch(
        [#dns_rr{data=#dns_rrdata_a{ip = {10, 0, 0, 49}}}],
        resolve(?DNAME("hello-host-vip-0-server",
                       "hello-world", "containerip"))).

%%%===================================================================
%%% Setup & cleanup
%%%===================================================================

basic_setup() ->
    setup(basic_setup).

hello_overlay_setup() ->
    setup(hello_overlay_setup).

setup(SetupFun) ->
    meck:new(lashup_kv),
    meck:expect(lashup_kv, value, fun value/1),
    meck:expect(lashup_kv, request_op, fun request_op/2),

    {ok, Apps} = ensure_all_started(erldns),
    Tasks = dcos_net_mesos_listener_tests:SetupFun(),
    {ok, Pid} = dcos_dns_mesos:start_link(),
    true =
        lists:any(fun (_) ->
            timer:sleep(100),
            recon:get_state(dcos_dns_mesos) =/= []
        end, lists:seq(1, 20)),

    {Tasks, Pid, Apps}.

cleanup({Tasks, Pid, Apps}) ->
    unlink(Pid),
    exit(Pid, kill),
    meck:unload(lashup_kv),

    lists:foreach(fun application:stop/1, Apps),
    lists:foreach(fun application:unload/1, Apps),

    dcos_net_mesos_listener_tests:cleanup(Tasks).

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
%%% Lashup mocks
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
