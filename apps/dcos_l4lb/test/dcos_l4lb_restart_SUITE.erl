-module(dcos_l4lb_restart_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    init_per_suite/1, end_per_suite/1,
    test_restart/1
]).

all() ->
    [test_restart].

init_per_suite(Config) ->
    os:cmd("ip link del minuteman"),
    os:cmd("ip link add minuteman type dummy"),
    Config.

end_per_suite(Config) ->
    os:cmd("ip link del minuteman"),
    dcos_l4lb_ipset_mgr:cleanup(),
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    Config.

test_restart(Config) ->
    PrivateDir = ?config(priv_dir, Config),
    lists:foreach(fun (_) ->
        application:load(dcos_l4lb),
        application:set_env(dcos_l4lb, agent_dets_basedir, PrivateDir),
        application:set_env(dcos_l4lb, enable_networking, enable_networking()),

        {ok, Apps} = application:ensure_all_started(dcos_l4lb),

        [ ok = application:stop(App) || App <- lists:reverse(Apps) ],
        [ ok = application:unload(App) || App <- lists:reverse(Apps) ]
    end, lists:seq(1, 3)).

enable_networking() ->
    os:cmd("id -u") =:= "0\n" andalso os:cmd("modprobe ip_vs") =:= "".
