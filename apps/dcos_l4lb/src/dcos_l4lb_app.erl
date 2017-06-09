-module(dcos_l4lb_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    dcos_net_app:load_config_files(dcos_l4lb),
    dcos_l4lb_sup:start_link([application:get_env(dcos_l4lb, enable_lb, true)]).

stop(_State) ->
    ok.
