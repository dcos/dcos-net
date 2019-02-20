-module(dcos_rest_metrics_handler).

-export([
    init/2,
    rest_init/2,
    allowed_methods/2,
    content_types_provided/2,
    metrics/2
]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

rest_init(Req, Opts) ->
    {ok, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[
        {{<<"text">>, <<"plain">>, '*'}, metrics}
    ], Req, State}.

metrics(Req, State) ->
    RegistryBin = cowboy_req:binding(registry, Req, <<"default">>),
    case prometheus_registry:exists(RegistryBin) of
        false ->
            Req0 = cowboy_req:reply(404, #{}, <<"Unknown Registry">>, Req),
            {stop, Req0, State};
        Registry ->
            CT = prometheus_text_format:content_type(),
            Req0 = cowboy_req:set_resp_header(<<"content-type">>, CT, Req),
            Data = prometheus_text_format:format(Registry),
            {Data, Req0, State}
    end.
