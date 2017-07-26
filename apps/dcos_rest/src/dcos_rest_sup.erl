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
            {"/status", dcos_rest_status_handler, []},
            {"/sfs/v1/object/[...]", dcos_rest_sfs_handler, [object]},
            {"/sfs/v1/stream", dcos_rest_sfs_handler, [stream]}
        ]}
    ]),
    lists:foreach(fun (IP) ->
        {ok, _} = cowboy:start_http(
            {dcos_rest, IP}, 100,
            [{ip, IP}, {port, dcos_rest_app:port()}],
            [{env, [{dispatch, Dispatch}]}])
    end, dcos_dns_config:bind_ips()).
