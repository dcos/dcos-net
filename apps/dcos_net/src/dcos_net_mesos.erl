-module(dcos_net_mesos).

-export([
    poll/1,
    call/1,
    call/3,
    request/2,
    init_metrics/0,
    http_options/0
]).

-export_type([response/0]).

-type response() :: {httpc:status_line(), httpc:headers(), Body :: binary()}.

-spec(poll(string()) -> {ok, jiffy:json_term()} | {error, Reason :: term()}).
poll(URIPath) ->
    Response = request(URIPath, [{"Accept", "application/json"}]),
    handle_response(Response).

-spec(call(jiffy:json_term()) -> Response
    when OKPayload :: {ok, jiffy:json_term()},
         OKReference :: {ok, reference(), pid()},
         Error :: {error, term()},
         Response :: OKPayload | OKReference | Error).
call(Request) ->
    call(Request, [], []).

-spec(call(jiffy:json_term(), httpc:http_options(), httpc:options()) -> Response
    when OKPayload :: {ok, jiffy:json_term()},
         OKReference :: {ok, reference(), pid()},
         Error :: {error, term()},
         Response :: OKPayload | OKReference | Error).
call(Request, HTTPOptions, Opts) ->
    Begin = erlang:monotonic_time(),
    ContentType = "application/json",
    HTTPRequest = {"/api/v1", [], ContentType, jiffy:encode(Request)},
    Opts0 = [{sync, false}|Opts],
    {ok, Ref} = request(post, HTTPRequest, HTTPOptions, Opts0),
    Timeout = application:get_env(dcos_net, mesos_timeout, 30000),
    Response = receive
        {http, {Ref, stream_start, _Headers, Pid}} ->
            {ok, Ref, Pid};
        {http, {Ref, {{_Version, 200, _Reason}, _Headers, Data}}} ->
            prometheus_counter:inc(
                mesos_listener, call_received_bytes_total, [], byte_size(Data)),
            {ok, jiffy:decode(Data, [return_maps])};
        {http, {Ref, {StatusLine, _Headers, Data}}} ->
            prometheus_counter:inc(mesos_listener, call_failures_total, [], 1),
            {error, {http_status, StatusLine, Data}};
        {http, {Ref, {error, Error}}} ->
            prometheus_counter:inc(mesos_listener, call_failures_total, [], 1),
            maybe_fatal_error(Error),
            {error, Error}
    after Timeout ->
        prometheus_counter:inc(mesos_listener, call_failures_total, [], 1),
        ok = httpc:cancel_request(Ref),
        {error, timeout}
    end,

    prometheus_summary:observe(
        mesos_listener, call_duration_seconds, [],
        erlang:monotonic_time() - Begin),
    Response.

-spec(request(string(), httpc:headers()) ->
    {ok, response()} | {error, Reason :: term()}).
request(URIPath, Headers) ->
    {ok, Ref} = request(get, {URIPath, Headers}, [], [{sync, false}]),
    Timeout = application:get_env(dcos_net, mesos_timeout, 30000),
    receive
        {http, {Ref, {error, Error}}} ->
            maybe_fatal_error(Error),
            {error, Error};
        {http, {Ref, Response}} ->
            {ok, Response}
    after Timeout ->
        ok = httpc:cancel_request(Ref),
        {error, timeout}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

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

-spec(handle_response({ok, response()} | {error, Reason :: term()}) ->
    {ok, jiffy:json_term()} | {error, Reason :: term()}).
handle_response({error, Reason}) ->
    {error, Reason};
handle_response({ok, {_StatusLine = {_HTTPVersion, 200 = _StatusCode, _ReasonPhrase}, _Headers, Body}}) ->
    {ok, jiffy:decode(Body, [return_maps])};
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

-spec(maybe_fatal_error(term()) -> ok | no_return()).
maybe_fatal_error({failed_connect, Info}) ->
    case lists:keyfind(inet, 1, Info) of
        {inet, _App, {options, {_Opt, Filename, {error, enoent}}}} ->
            % NOTE: Systemd will restart dcos-net immediately
            % and bootstrap script will re-initialize all the certificates.
            halt("TLS is broken, " ++ Filename ++ " doesn't exist.");
        _Other ->
            ok
    end;
maybe_fatal_error(_Error) ->
    ok.

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(init_metrics() -> ok).
init_metrics() ->
    prometheus_summary:new([
        {registry, mesos_listener},
        {name, call_duration_seconds},
        {help, "The time spent with calls to the Mesos operator API."}]),
    prometheus_counter:new([
        {registry, mesos_listener},
        {name, call_received_bytes_total},
        {help, "Total number of bytes received from Mesos operator API."}]),
    prometheus_counter:new([
        {registry, mesos_listener},
        {name, call_failures_total},
        {help, "Total number of failures calling Mesos operator API."}]).
