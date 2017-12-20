%%-------------------------------------------------------------------
%% @author dgoel
%% @copyright (C) 2017, <COMPANY>
%% @doc
%% K8s apiserver client
%%
%% @end
%% Created : 25 Oct 2017 9:14 AM
%%-------------------------------------------------------------------

-module(dcos_l4lb_k8s_client).
-author("dgoel").

-define(APP, dcos_l4lb).
-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_CONNECT_TIMEOUT, 30000).

%%API
-export([get/3, get/2]).

get(URI, Path, QueryParams) ->
    Endpoint = URI ++ "/" ++ Path ++ "?" ++ QueryParams,
    Response = fetch(Endpoint),
    handle_response(Response).

get(URI, Path) ->
    Endpoint = lists:flatten(URI ++ "/" ++ Path),
    Response = fetch(Endpoint),
    handle_response(Response).

fetch(Endpoint) ->
    Options = [
        {timeout, application:get_env(?APP, timeout, ?DEFAULT_TIMEOUT)},
        {connect_timeout, application:get_env(?APP, connect_timeout, ?DEFAULT_CONNECT_TIMEOUT)}
    ],
    Headers = [{"Accept", "application/json"}],
    httpc:request(get, {Endpoint, Headers}, Options, [{body_format, binary}]).

handle_response({error, Reason}) ->
    {error, Reason};
handle_response({ok, {_StatusLine = {_HTTPVersion, 200 = _StatusCode, _ReasonPhrase}, _Headers, Body}}) ->
    parse_response(Body);
handle_response({ok, {StatusLine, _Headers, _Body}}) ->
    {error, StatusLine}.

parse_response(Body) ->
    ParsedBody = jsx:decode(Body, [return_maps]),
    {ok, ParsedBody}.
