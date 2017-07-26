-module(dcos_rest_app).
-behaviour(application).
-export([start/2, stop/1]).

-export([
    port/0
]).

start(_StartType, _StartArgs) ->
    dcos_net_app:load_config_files(dcos_rest),
    dcos_rest_sup:start_link(application:get_env(dcos_rest, enable_rest, true)).

stop(_State) ->
    ok.

port() ->
    application:get_env(dcos_rest, port, 62080).
