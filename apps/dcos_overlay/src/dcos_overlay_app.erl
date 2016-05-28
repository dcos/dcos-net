%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module(dcos_overlay_app).

-behaviour(application).

%% Application callbacks
-export([start/2
    ,stop/1]).
-define(DEFAULT_CONFIG_LOCATION, "/opt/mesosphere/etc/navstar.app.config").

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    load_config(),
    'dcos_overlay_sup':start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.


load_config() ->
    case file:consult(?DEFAULT_CONFIG_LOCATION) of
        {ok, Result} ->
            load_config(Result),
            lager:info("Loaded config: ~p", [?DEFAULT_CONFIG_LOCATION]);
        {error, enoent} ->
            lager:info("Did not load config: ~p", [?DEFAULT_CONFIG_LOCATION])
    end.

load_config([Result = [_]]) ->
    lists:foreach(fun load_app_config/1, Result).

load_app_config({App, Options}) ->
    lists:foreach(fun({OptionKey, OptionValue}) -> application:set_env(App, OptionKey, OptionValue) end, Options).
