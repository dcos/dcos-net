-module(dcos_rest_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

start_link(Enabled) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Enabled]).

init([false]) ->
    {ok, {#{}, []}};
init([true]) ->
    setup_cowboy(),
    {ok, {#{}, []}}.

setup_cowboy() ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/lashup/kv/[...]", dcos_rest_lashup_handler, []},
            {"/lashup/key", dcos_rest_key_handler, []},
            {"/v1/vips", dcos_rest_vips_handler, []},
            {"/status", dcos_rest_status_handler, []}
        ]}
    ]),
    Ip = application:get_env(navstar, ip, {127, 0, 0, 1}),
    Port = application:get_env(navstar, port, 62080),
    {ok, _} = cowboy:start_http(http, 100, [{ip, Ip}, {port, Port}], [
        {env, [{dispatch, Dispatch}]}
    ]).
