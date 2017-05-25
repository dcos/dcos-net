%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module(dcos_overlay_app).
-behaviour(application).

%% Application callbacks
-export([start/2,
         stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    dcos_overlay_sup:start_link([application:get_env(dcos_overlay, enable_overlay, true)]).

stop(_State) ->
    ok.
