-module(dcos_l4lb_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    dcos_l4lb_metrics:setup(),
    dcos_l4lb_sup:start_link().

stop(_State) ->
    ok.
