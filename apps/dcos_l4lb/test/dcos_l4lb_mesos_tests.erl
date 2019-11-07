-module(dcos_l4lb_mesos_tests).

-include_lib("eunit/include/eunit.hrl").
-include("dcos_l4lb.hrl").

%%%===================================================================
%%% Tests
%%%===================================================================

vip_labels_test_() ->
    {setup, fun vip_labels_setup/0, fun cleanup/1, {with, [
        fun vip_labels/1
    ]}}.

tcp_udp_test_() ->
    {setup, fun tcp_udp_setup/0, fun cleanup/1, {with, [
        fun tcp_udp/1
    ]}}.

vip_labels({VIPs, _Pid}) ->
    TaskId = <<"app.c9e19be4-6a94-11e8-bfc9-70b3d5800002">>,
    FrameworkId = <<"3de98647-82e7-4a22-8fb5-32df27c1ef69-0001">>,
    Backend = #{
        task_id => {FrameworkId, TaskId},
        agent_ip => {172, 17, 0, 3},
        task_ip => [{172, 17, 0, 3}],
        runtime => mesos
    },
    ?assertEqual(#{
        {tcp, {<<"/abc">>, <<"marathon">>}, 80} => [Backend#{port => 9999}],
        {tcp, {<<"/cbd">>, <<"marathon">>}, 80} => [Backend#{port => 9999}],
        {tcp, {<<"def">>, <<"marathon">>}, 80} => [Backend#{port => 9999}],
        {tcp, {<<"jkl">>, <<"marathon">>}, 80} => [Backend#{port => 10000}],
        {tcp, {<<"/xyz">>, <<"marathon">>}, 443} => [Backend#{port => 10001}]
    }, VIPs).

tcp_udp({VIPs, _Pid}) ->
    TaskId = <<"app.80eefa01-d956-11e8-8b68-70b3d5800002">>,
    FrameworkId = <<"0e559f52-e43a-497a-90b8-11688d98f60c-0000">>,
    Backend = #{
        task_id => {FrameworkId, TaskId},
        agent_ip => {172, 17, 0, 3},
        task_ip => [{172, 17, 0, 3}],
        runtime => docker,
        port => 6416
    },
    ?assertEqual(#{
        {tcp, {<<"/app">>, <<"marathon">>}, 80} => [Backend],
        {udp, {<<"/app">>, <<"marathon">>}, 80} => [Backend]
    }, VIPs).

%%%===================================================================
%%% Setup & cleanup
%%%===================================================================

vip_labels_setup() ->
    setup("vip-labels.json").

tcp_udp_setup() ->
    setup("tcp-and-udp.json").

setup(FileName) ->
    Tasks = dcos_net_mesos_listener_tests:from_state(FileName),

    T = ets:new(?MODULE, [public]),
    meck:new(lashup_kv),
    meck:expect(lashup_kv, request_op, request_op_fun(T)),

    Ref = make_ref(),
    meck:new(dcos_net_mesos_listener),
    meck:expect(dcos_net_mesos_listener, subscribe, fun () -> {ok, Ref} end),
    meck:expect(dcos_net_mesos_listener, next, fun (_Ref) -> ok end),

    DefaultHandlerMounted = lists:member(default, logger:get_handler_ids()),
    case DefaultHandlerMounted of
        true -> ok = logger:remove_handler(default);
        _ -> ok
    end,

    {ok, Pid} = dcos_l4lb_mesos:start_link(),
    dcos_l4lb_mesos ! {{tasks, Tasks}, Ref},
    true =
        lists:any(fun (_) ->
            timer:sleep(100),
            recon:get_state(dcos_l4lb_mesos) =/= []
        end, lists:seq(1, 20)),

    [{vips, VIPs}] = ets:lookup(T, vips),
    {VIPs, Pid}.

cleanup({_VIPs, Pid}) ->
    unlink(Pid),
    exit(Pid, kill),
    meck:unload(lashup_kv),
    meck:unload(dcos_net_mesos_listener).

%%%===================================================================
%%% Lashup mocks
%%%===================================================================

request_op_fun(T) ->
    fun (?VIPS_KEY3, {update, Updates}) ->
        [{update, ?VIPS_FIELD, Op}] = Updates,
        {assign, VIPs, _Timestamp} = Op,
        ets:insert(T, {vips, VIPs}),
        {ok, [{?VIPS_FIELD, Op}]}
    end.
