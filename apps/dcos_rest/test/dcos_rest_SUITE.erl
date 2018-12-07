-module(dcos_rest_SUITE).

-export([
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2,
    json_ok/1,
    skip/1
]).

all() ->
    [json_ok, skip].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(mnesia),
    {ok, _} = application:ensure_all_started(lashup),
    {ok, _} = application:ensure_all_started(dcos_dns),
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    {ok, _} = application:ensure_all_started(dcos_net),
    {ok, _} = application:ensure_all_started(dcos_rest),
    Config.

end_per_suite(_Config) ->
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    ok.

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, _Config) ->
    ok.

json_ok(_Config) ->
    lists:foreach(fun (Path) ->
        ct:pal("checking ~s", [Path]),
        {ok, {{_V, 200, "OK"}, _H, Body}} =
            httpc:request(
                get, {"http://localhost:62080" ++ Path, []},
                [], [{body_format, binary}]),
        _ = jiffy:decode(Body)
    end, [
        "/v1/vips",
        "/v1/nodes",
        "/v1/version",
        "/v1/records"
    ]).

skip(_Config) ->
    lists:foreach(fun (Path) ->
        ct:pal("checking ~s", [Path]),
        {ok, {_S, _H, _B}} =
            httpc:request(
                get, {"http://localhost:62080" ++ Path, []},
                [], [{body_format, binary}])
    end, [
        "/lashup/key",
        "/v1/config",
        "/v1/hosts/foobar",
        "/v1/services/bazqux",
        "/v1/enumerate"
    ]).
