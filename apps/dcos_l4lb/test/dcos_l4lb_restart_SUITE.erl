-module(dcos_l4lb_restart_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() ->
    [test_restart].

init_per_suite(Config) ->
    os:cmd("ip link del minuteman"),
    os:cmd("ip link add minuteman type dummy"),
    Config.

end_per_suite(Config) ->
    os:cmd("ip link del minuteman"),
    Config.

test_restart(Config) ->
    PrivateDir = ?config(priv_dir, Config),
    application:load(dcos_l4lb),
    application:set_env(dcos_l4lb, agent_dets_basedir, PrivateDir),
    application:set_env(dcos_l4lb, enable_networking, enable_networking()),

    {ok, _} = application:ensure_all_started(dcos_l4lb),
    ok = application:stop(dcos_l4lb),
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    ok = application:stop(dcos_l4lb),
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    ok = application:stop(dcos_l4lb),

    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*").

enable_networking() ->
    os:cmd("id -u") =:= "0\n" andalso os:cmd("modprobe ip_vs") =:= "".
