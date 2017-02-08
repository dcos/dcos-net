-module(dcos_l4lb_mesos_poller_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include("minuteman.hrl").


%% root tests
all() ->
  [test_gen_server, test_handle_poll_state].

test_gen_server(_Config) ->
    hello = erlang:send(dcos_l4lb_mesos_poller, hello),
    ok = gen_server:call(dcos_l4lb_mesos_poller, hello),
    ok = gen_server:cast(dcos_l4lb_mesos_poller, hello),
    sys:suspend(dcos_l4lb_mesos_poller),
    sys:change_code(dcos_l4lb_mesos_poller, random_old_vsn, dcos_l4lb_mesos_poller, []),
    sys:resume(dcos_l4lb_mesos_poller).

test_handle_poll_state(Config) ->
    AgentIP = {1, 1, 1, 1},
    DataDir = ?config(data_dir, Config),
    %%ok = mnesia:dirty_delete(kv2, [minuteman, vips]),
    {ok, Data} = file:read_file(filename:join(DataDir, "named-base-vips.json")),
    {ok, MesosState} = mesos_state_client:parse_response(Data),
    State0 = {state, AgentIP, ordsets:new(), 0},
    State1 = dcos_l4lb_mesos_poller:handle_poll_state(MesosState, State0),
    LashupValue = lashup_kv:value([minuteman, vips]),
    [{_, [{{10, 0, 0, 243}, 12049}]}] = LashupValue,
    {ok, Name} = dets:open_file(dcos_l4lb_config:agent_dets_path("agent_be"), []),
    DetsValue = dets:lookup(Name, AgentIP),
    [{AgentIP, [{10, 0, 0, 243}]}] = DetsValue,
    {state, AgentIP, [{10, 0, 0, 243}], _} = State1.

init_per_suite(Config) ->
  os:cmd("rm -rf Mnesia.nonode@nohost/*"),
  os:cmd("rm -rf nonode@nohost/*"),
  Config.

init_per_testcase(_, Config) ->
  PrivateDir = ?config(priv_dir, Config),
  application:set_env(dcos_l4lb, agent_dets_basedir, PrivateDir),
  application:set_env(dcos_l4lb, enable_networking, false),
  {ok, _} = application:ensure_all_started(minuteman),
  Config.

end_per_testcase(_, _Config) ->
  ok = application:stop(minuteman),
  ok = application:stop(lashup),
  ok = application:stop(mnesia).
