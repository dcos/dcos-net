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
            {"/v1/nodes", dcos_rest_nodes_handler, []},

            {"/v1/version", dcos_rest_dns_handler, [version]},
            {"/v1/config", dcos_rest_dns_handler, [config]},
            {"/v1/hosts/:host", dcos_rest_dns_handler, [hosts]},
            {"/v1/services/:service", dcos_rest_dns_handler, [services]},
            {"/v1/enumerate", dcos_rest_dns_handler, [enumerate]},
            {"/v1/records", dcos_rest_dns_handler, [records]}
        ]}
    ]),
    {ok, Ip} = application:get_env(dcos_rest, ip),
    {ok, Port} = application:get_env(dcos_rest, port),
    {ok, _} = cowboy:start_clear(
        http, [{ip, Ip}, {port, Port}], #{
            env => #{dispatch => Dispatch}
        }).
