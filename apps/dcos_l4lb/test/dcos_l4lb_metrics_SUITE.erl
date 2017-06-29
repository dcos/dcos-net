-module(dcos_l4lb_metrics_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include("dcos_l4lb.hrl").

all() -> [test_init,
          test_reorder,
          test_push_metrics,
          test_named_vip,
          test_wait_metrics,
          test_new_data,
          test_one_conn,
          test_gen_server].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(Test, Config) ->
    application:load(ip_vs_conn),
    application:set_env(ip_vs_conn, proc_file, proc_file(Config, Test)),
    set_interval(Test),
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    Config.

end_per_testcase(_, _Config) ->
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    ok.

test_init(_Config) -> ok.
test_gen_server(_Config) ->
    hello = erlang:send(dcos_l4lb_metrics, hello),
    ok = gen_server:call(dcos_l4lb_metrics, hello),
    ok = gen_server:cast(dcos_l4lb_metrics, hello),
    sys:suspend(dcos_l4lb_metrics),
    sys:change_code(dcos_l4lb_metrics, random_old_vsn, dcos_l4lb_metrics, []),
    sys:resume(dcos_l4lb_metrics).

test_push_metrics(_Config) ->
    push_metrics = erlang:send(dcos_l4lb_metrics, push_metrics),
    timer:sleep(2000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

test_wait_metrics(_Config) ->
    timer:sleep(2000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

test_new_data(Config) ->
    push_metrics = erlang:send(dcos_l4lb_metrics, push_metrics),
    timer:sleep(1000),
    R = telemetry_store:reap(),
    ct:pal("reaped1 ~p", [R]),
    DataDir = ?config(data_dir, Config),
    ProcFile = DataDir ++ "/proc_ip_vs_conn3",
    application:set_env(ip_vs_conn, proc_file, ProcFile),
    push_metrics = erlang:send(dcos_l4lb_metrics, push_metrics),
    timer:sleep(1000),
    R2 = telemetry_store:reap(),
    ct:pal("reaped2 ~p", [R2]),
    ok.

test_reorder(_Config) ->
    push_metrics = erlang:send(dcos_l4lb_metrics, push_metrics),
    timer:sleep(1000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

test_one_conn(_Config) ->
    push_metrics = erlang:send(dcos_l4lb_metrics, push_metrics),
    timer:sleep(1000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

test_named_vip(_Config) ->
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{update,
                  {{tcp, {name, {<<"de8b9dc86">>, <<"marathon">>}}, 8080}, riak_dt_orswot},
                   {add, {{10, 0, 79, 182}, {{10, 0, 79, 182}, 8080}}}}]}),
    [{ip, IP}] = dcos_l4lb_lashup_vip_listener:lookup_vips([{name, <<"de8b9dc86.marathon">>}]),
    ct:pal("change the testdata if it doesn't match ip: ~p", [IP]),
    push_metrics = erlang:send(dcos_l4lb_metrics, push_metrics),
    timer:sleep(2000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

proc_file(Config, test_one_conn) ->
    DataDir = ?config(data_dir, Config),
    DataDir ++ "/proc_ip_vs_conn1";
proc_file(Config, _) ->
    DataDir = ?config(data_dir, Config), DataDir ++ "/proc_ip_vs_conn2".

set_interval(test_wait_metrics) ->
    application:load(dcos_l4lb),
    application:set_env(dcos_l4lb, metrics_interval_seconds, 1),
    application:set_env(dcos_l4lb, metrics_splay_seconds, 1);
set_interval(_) -> ok.
