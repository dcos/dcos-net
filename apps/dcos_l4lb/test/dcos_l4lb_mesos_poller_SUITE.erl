-module(dcos_l4lb_mesos_poller_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include("dcos_l4lb.hrl").


%% root tests
all() ->
  [test_gen_server, test_handle_poll_state].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_, Config) ->
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

test_gen_server(_Config) ->
    hello = erlang:send(dcos_l4lb_mesos_poller, hello),
    ok = gen_server:call(dcos_l4lb_mesos_poller, hello),
    ok = gen_server:cast(dcos_l4lb_mesos_poller, hello),
    sys:suspend(dcos_l4lb_mesos_poller),
    sys:change_code(dcos_l4lb_mesos_poller, random_old_vsn, dcos_l4lb_mesos_poller, []),
    sys:resume(dcos_l4lb_mesos_poller).

test_handle_poll_state(Config) ->
    AgentIP = {10, 0, 0, 243},
    DataDir = ?config(data_dir, Config),
    %%ok = mnesia:dirty_delete(kv2, [minuteman, vips]),
    {ok, Data} = file:read_file(filename:join(DataDir, "named-base-vips.json")),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    State = {state, AgentIP, 0},
    dcos_l4lb_mesos_poller:handle_poll_state(MesosState, State),
    LashupValue2 = lashup_kv:value(?VIPS_KEY2),
    [{_, [{{10, 0, 0, 243}, {{10, 0, 0, 243}, 12049}}]}] = LashupValue2.

