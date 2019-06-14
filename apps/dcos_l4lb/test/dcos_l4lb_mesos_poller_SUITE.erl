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
    meck:new(dcos_net_mesos_listener, [no_link, passthrough]),
    meck:expect(dcos_net_mesos_listener, poll, fun meck_mesos_poll/0),

    meck:new(dcos_l4lb_mgr, [no_link]),
    meck:expect(dcos_l4lb_mgr, local_port_mappings, fun (_) -> ok end),
    meck:expect(dcos_l4lb_mgr, push_vips, fun (_) -> ok end),

    {ok, _} = application:ensure_all_started(dcos_l4lb),
    meck:wait(dcos_net_mesos_listener, poll, '_', 5000),
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
    meck:unload(dcos_net_mesos_listener),
    meck:unload(dcos_l4lb_mgr),
    dcos_l4lb_ipset_mgr:cleanup(),
    ok.

meck_mesos_poll() ->
    {ok, #{
        <<"app.6e53a5c1-1f27-11e6-bc04-4e40412869d8">> => #{
            name => <<"app">>,
            runtime => mesos,
            framework => <<"marathon">>,
            agent_ip => {10, 0, 0, 243},
            task_ip => [{9, 0, 1, 29}],
            ports => [
                #{name => <<"http">>, protocol => tcp, host_port => 12049,
                  port => 80, vip => [<<"merp:5000">>]}
            ],
            state => running
        }
    }}.

test_lashup(_Config) ->
    Value = lashup_kv:value(?VIPS_KEY2),
    [{_, [{{10, 0, 0, 243}, {{10, 0, 0, 243}, 12049}}]}] = Value.

test_mesos_portmapping(_Config) ->
    Expected = [{{tcp, 12049}, {{9, 0, 1, 29}, 80}}],
    Actual = meck:capture(first, dcos_l4lb_mgr, local_port_mappings, '_', 1),
    ?assertMatch(Expected, Actual).
