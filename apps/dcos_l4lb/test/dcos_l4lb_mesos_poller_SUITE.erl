-module(dcos_l4lb_mesos_poller_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("dcos_l4lb.hrl").

-export([
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2,
    test_lashup/1
]).


%% root tests
all() ->
    [test_lashup].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_, Config) ->
    meck:new(dcos_net_mesos_listener, [no_link]),
    meck:expect(dcos_net_mesos_listener, poll, fun () ->
        {ok, #{
            <<"app.6e53a5c1-1f27-11e6-bc04-4e40412869d8">> => #{
                name => <<"app">>,
                framework => <<"marathon">>,
                agent_ip => {10, 0, 0, 243},
                task_ip => [{10, 0, 0, 243}],
                ports => [
                    #{name => <<"http">>, protocol => tcp,
                      port => 12049, vip => [<<"merp:5000">>]}
                ],
                state => running
            }
        }}
    end),
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    meck:wait(dcos_net_mesos_listener, poll, '_', 5000),
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
    ok.

test_lashup(_Config) ->
    Value = lashup_kv:value(?VIPS_KEY2),
    [{_, [{{10, 0, 0, 243}, {{10, 0, 0, 243}, 12049}}]}] = Value.
