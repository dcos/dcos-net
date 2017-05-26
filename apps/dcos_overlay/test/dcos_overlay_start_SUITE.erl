-module(dcos_overlay_start_SUITE).

-include_lib("common_test/include/ct.hrl").

%% common_test callbacks
-export([
    all/0,
    init_per_testcase/2, end_per_testcase/2
]).

%% tests
-export([
    dcos_overlay_start/1
]).

-define(DEFAULT_CONFIG_DIR, "/opt/mesosphere/etc/navstar.config.d").

init_per_testcase(_TestCase, Config) ->
    meck:new(file, [unstick, passthrough]),
    meck:expect(file, list_dir,
        fun (?DEFAULT_CONFIG_DIR) ->
                meck:passthrough([?config(data_dir, Config)]);
            (Dir) ->
                meck:passthrough([Dir])
        end),
    meck:expect(file, consult,
        fun (?DEFAULT_CONFIG_DIR ++ File) ->
                meck:passthrough([?config(data_dir, Config) ++ File]);
            (File) ->
                meck:passthrough([File])
        end),
    meck:new(dcos_overlay_sup, [passthrough]),
    meck:expect(dcos_overlay_sup, init, fun (_) -> {ok, {#{}, []}} end),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok = meck:unload(dcos_overlay_sup),
    ok = meck:unload(file).

all() ->
    [dcos_overlay_start].

dcos_overlay_start(_Config) ->
    navstar_start(dcos_overlay, baz, overlay).

navstar_start(App, Env, Value) ->
    undefined = application:get_env(App, common, undefined),
    undefined = application:get_env(App, Env, undefined),
    {ok, _} = application:ensure_all_started(App),
    Value = application:get_env(App, Env, undefined),
    navstar = application:get_env(App, common, undefined),
    ok = application:stop(App).
