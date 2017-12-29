-module(dcos_net_mesos).

-export([
    request/2,
    poll/1
]).

-export_type([response/0]).

-type response() :: {httpc:status_line(), httpc:headers(), Body :: binary()}.

-spec(poll(string()) -> {ok, mesos_state_client:mesos_agent_state()} | {error, Reason :: term()}).
poll(URIPath) ->
    Response = request(URIPath, [{"Accept", "application/json"}]),
    handle_response(Response).

-spec(request(string(), httpc:headers()) -> {ok, response()} | {error, Reason :: term()}).
request(URIPath, Headers) ->
    Options = [
        {timeout, application:get_env(dcos_net, mesos_timeout, 30000)},
        {connect_timeout, application:get_env(dcos_net, mesos_connect_timeout, 30000)} |
        mesos_http_options()
    ],
    Headers0 = maybe_add_token(Headers),
    Headers1 = add_useragent(Headers0),
    httpc:request(get, {mesos_uri(URIPath), Headers1}, Options, [{body_format, binary}]).

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
        case dcos_dns:is_master() of
            true -> 5050;
            false -> 5051
        end,
    Port = application:get_env(dcos_net, mesos_port, PortDefault),
    Hostname = binary_to_list(dcos_net_dist:hostname()),
    lists:concat([Protocol, "://", Hostname, ":", Port, Path]).

-spec mesos_http_options() -> [{ssl, ssl:ssl_options()}].
mesos_http_options() ->
    case dcos_net_dist:ssl_dist_opts() of
        false ->
            [];
        DistOpts ->
            {client, Opts} = lists:keyfind(client, 1, DistOpts),
            [{ssl, Opts}]
    end.
