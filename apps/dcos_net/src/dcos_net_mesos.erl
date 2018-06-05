-module(dcos_net_mesos).

-export([
    poll/1,
    call/1,
    call/3,
    request/2,
    request/4,
    http_options/0
]).

-export_type([response/0]).

-type response() :: {httpc:status_line(), httpc:headers(), Body :: binary()}.

-spec(poll(string()) -> {ok, MesosState} | {error, Reason :: term()}
    when MesosState :: mesos_state_client:mesos_agent_state()).
poll(URIPath) ->
    Response = request(URIPath, [{"Accept", "application/json"}]),
    handle_response(Response).

-spec(call(jiffy:json_term()) ->
    {ok, jiffy:json_term()} | {error, Reason :: term()}).
call(Request) ->
    call(Request, [], []).

-spec(call(jiffy:json_term(), httpc:http_options(), httpc:options()) ->
    {ok, jiffy:json_term()} | {ok, reference(), pid()} | {error, term()}).
call(Request, HTTPOptions, Opts) ->
    ContentType = "application/json",
    HTTPRequest = {"/api/v1", [], ContentType, jiffy:encode(Request)},
    Opts0 = [{sync, false}|Opts],
    {ok, Ref} = dcos_net_mesos:request(post, HTTPRequest, HTTPOptions, Opts0),
    Timeout = application:get_env(dcos_net, mesos_timeout, 30000),
    receive
        {http, {Ref, stream_start, _Headers, Pid}} ->
            {ok, Ref, Pid};
        {http, {Ref, {{_Version, 200, _Reason}, _Headers, Data}}} ->
            {ok, jiffy:decode(Data, [return_maps])};
        {http, {Ref, {StatusLine, _Headers, Data}}} ->
            {error, {http_status, StatusLine, Data}};
        {http, {Ref, {error, Error}}} ->
            {error, Error}
    after Timeout ->
        ok = httpc:cancel_request(Ref),
        {error, timeout}
    end.

-spec(request(string(), httpc:headers()) ->
    {ok, response()} | {error, Reason :: term()}).
request(URIPath, Headers) ->
    {ok, Ref} = request(get, {URIPath, Headers}, [], [{sync, false}]),
    Timeout = application:get_env(dcos_net, mesos_timeout, 30000),
    receive
        {http, {Ref, {error, Error}}} ->
            {error, Error};
        {http, {Ref, Response}} ->
            {ok, Response}
    after Timeout ->
        ok = httpc:cancel_request(Ref),
        {error, timeout}
    end.

-spec(request(
    httpc:method(), httpc:request(),
    httpc:http_options(), httpc:options()
) -> {ok, response() | reference()} | {error, Reason :: term()}).
request(Method, Request, HTTPOptions, Opts) ->
    URIPath = element(1, Request),
    Headers = element(2, Request),
    URI = mesos_uri(URIPath),
    Headers0 = maybe_add_token(Headers),
    Headers1 = add_useragent(Headers0),
    Request0 = setelement(1, Request, URI),
    Request1 = setelement(2, Request0, Headers1),
    httpc:request(Method, Request1, mesos_http_options(HTTPOptions), Opts).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(handle_response({ok, response()} | {error, Reason :: term()}) ->
    {ok, mesos_state_client:mesos_agent_state()} | {error, Reason :: term()}).
handle_response({error, Reason}) ->
    {error, Reason};
handle_response({ok, {_StatusLine = {_HTTPVersion, 200 = _StatusCode, _ReasonPhrase}, _Headers, Body}}) ->
    mesos_state_client:parse_response(Body);
handle_response({ok, {StatusLine, _Headers, _Body}}) ->
    {error, StatusLine}.

-spec(format_token(string()) -> string()).
format_token(AuthToken) ->
    lists:flatten("token=" ++ AuthToken).

-spec(maybe_add_token(httpc:headers()) -> httpc:headers()).
maybe_add_token(Headers) ->
    case os:getenv("SERVICE_AUTH_TOKEN") of
        false ->
            Headers;
        AuthToken0 ->
            AuthToken1 = format_token(AuthToken0),
            [{"Authorization", AuthToken1}|Headers]
    end.

-spec(add_useragent(httpc:headers()) -> httpc:headers()).
add_useragent(Headers) ->
    UserAgent = lists:concat([atom_to_list(node()), " (pid ", os:getpid(), ")"]),
    [{"User-Agent", UserAgent}|Headers].

-spec(mesos_uri(string()) -> string()).
mesos_uri(Path) ->
    Protocol =
        case dcos_net_dist:ssl_dist_opts() of
            false -> "http";
            _Opts -> "https"
        end,
    PortDefault =
        case dcos_net_app:is_master() of
            true -> 5050;
            false -> 5051
        end,
    Port = application:get_env(dcos_net, mesos_port, PortDefault),
    Hostname = binary_to_list(dcos_net_dist:hostname()),
    lists:concat([Protocol, "://", Hostname, ":", Port, Path]).

-spec(http_options() -> httpc:http_options()).
http_options() ->
    Timeout = application:get_env(dcos_net, mesos_timeout, 30000),
    CTimeout = application:get_env(dcos_net, mesos_connect_timeout, 5000),
    [{timeout, Timeout}, {connect_timeout, CTimeout}, {autoredirect, false}].

-spec(mesos_http_options(httpc:http_options()) -> httpc:http_options()).
mesos_http_options(HTTPOptions) ->
    HTTPOptions0 = http_options() ++ mesos_http_options(),
    lists:foldl(fun ({Key, Value}, Acc) ->
        [{Key, Value}|lists:keydelete(Key, 1, Acc)]
    end, HTTPOptions0, HTTPOptions).

-spec mesos_http_options() -> [{ssl, ssl:ssl_options()}].
mesos_http_options() ->
    case dcos_net_dist:ssl_dist_opts() of
        false ->
            [];
        DistOpts ->
            {client, Opts} = lists:keyfind(client, 1, DistOpts),
            [{ssl, Opts}]
    end.
