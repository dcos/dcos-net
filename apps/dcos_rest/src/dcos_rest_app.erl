%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module(dcos_rest_app).

-behaviour(application).

%% Application callbacks
-export([
    start/2,
    stop/1
]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    dcos_net_app:load_config_files(dcos_rest),
    setup_cowboy(),
    dcos_rest_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
setup_cowboy() ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/lashup/kv/[...]", dcos_rest_lashup_handler, []},
            {"/lashup/key", dcos_rest_key_handler, []},
            {"/v1/vips", dcos_rest_vips_handler, []}
        ]}
    ]),
    Ip = application:get_env(navstar, ip, {127, 0, 0, 1}),
    Port = application:get_env(navstar, port, 62080),
    {ok, _} = cowboy:start_http(http, 100, [{ip, Ip}, {port, Port}], [
        {env, [{dispatch, Dispatch}]}
    ]).
