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
    ok = init_metrics(),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/lashup/kv/[...]", dcos_rest_lashup_handler, []},
            {"/lashup/key", dcos_rest_key_handler, []},
            {"/v1/vips", dcos_rest_vips_handler, []},

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
    StreamHandlers = [cowboy_metrics_h, cowboy_stream_h],

    {ok, _} = cowboy:start_clear(
        http, [{ip, Ip}, {port, Port}], #{
            env => #{dispatch => Dispatch},
            stream_handlers => StreamHandlers,
            metrics_callback => fun metrics_fun/1
        }).

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(metrics_fun(cowboy_metrics_h:metrics()) -> any()).
metrics_fun(#{req_start := ReqStart, req_end := ReqEnd,
              resp_status := Status}) ->
    ok = folsom_metrics:notify(
        {rest, response_ms},
        (ReqEnd - ReqStart) div 1000 / 1000),
    ok = folsom_metrics:notify({rest, requests}, {inc, 1}, counter),
    ok = folsom_metrics:notify({rest, statuses, Status}, {inc, 1}, counter).

-define(SLIDE_WINDOW, 5). % seconds
-define(SLIDE_SIZE, 1024).

-spec(init_metrics() -> ok).
init_metrics() ->
    folsom_metrics:new_histogram(
        {rest, response_ms}, slide_uniform,
        {?SLIDE_WINDOW, ?SLIDE_SIZE}).
