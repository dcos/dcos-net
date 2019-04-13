-module(dcos_l4lb_mesos_poller_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include("dcos_l4lb.hrl").

-export([
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2
]).

-export([
    test_lashup/1,
    test_mesos_portmapping/1
]).


%% root tests
all() -> [
    test_lashup,
    test_mesos_portmapping
].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_, Config) ->
    meck:new(dcos_net_mesos, [no_link]),
    meck:expect(dcos_net_mesos, poll, fun (_) -> meck_mesos_poll(Config) end),

    meck:new(dcos_l4lb_mgr, [no_link]),
    meck:expect(dcos_l4lb_mgr, local_port_mappings, fun (_) -> ok end),

    {ok, _} = application:ensure_all_started(dcos_l4lb),
    meck:wait(dcos_net_mesos, poll, '_', 5000),
    meck:wait(dcos_l4lb_mgr, local_port_mappings, '_', 100),
    timer:sleep(100),
    Config.

end_per_testcase(_, _Config) ->
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    meck:unload(dcos_net_mesos),
    meck:unload(dcos_l4lb_mgr),
    dcos_l4lb_ipset_mgr:cleanup(),
    ok.

meck_mesos_poll(Config) ->
    DataDir = ?config(data_dir, Config),
    {ok, Data} = file:read_file(filename:join(DataDir, "state.json")),
    mesos_state_client:parse_response(Data).

test_lashup(_Config) ->
    Value = lashup_kv:value(?VIPS_KEY2),
    [{_, [{{10, 0, 0, 40}, {{10, 0, 0, 40}, 12564}}]}] = Value.

test_mesos_portmapping(_Config) ->
    Expected = [{{tcp, 12564}, {{9, 0, 2, 2}, 80}}],
    Actual = meck:capture(first, dcos_l4lb_mgr, local_port_mappings, '_', 1),
    ?assertMatch(Expected, Actual).
