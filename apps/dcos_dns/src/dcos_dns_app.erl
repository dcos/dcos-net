-module(dcos_dns_app).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(application).
-export([start/2, stop/1]).

%% Application
-export([
    wait_for_reqid/2,
    parse_ipv4_address/1,
    parse_ipv4_address_with_port/2,
    parse_upstream_name/1
]).

-include("dcos_dns.hrl").
-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-define(TCP_LISTENER_NAME, dcos_dns_tcp_listener).

-define(COMPILE_OPTIONS,
        [verbose,
         report_errors,
         report_warnings,
         no_error_module_mismatch,
         {source, undefined}]).


%%====================================================================
%% Application Behavior
%%====================================================================

start(_StartType, _StartArgs) ->
    maybe_load_json_config(), %% Maybe load the relevant DCOS configuration
    Ret = dcos_dns_sup:start_link(),
    maybe_start_tcp_listener(),
    maybe_start_http_listener(),
    Ret.

stop(_State) ->
    ranch:stop_listener(?TCP_LISTENER_NAME),
    ok.

%%====================================================================
%% General API
%%====================================================================

%% @doc Wait for a response.
wait_for_reqid(ReqID, Timeout) ->
    receive
        {ReqID, ok} ->
            ok;
        {ReqID, ok, Val} ->
            {ok, Val}
    after Timeout ->
        {error, timeout}
    end.

%% @doc Parse an IPv4 Address
-spec(parse_ipv4_address(binary()|list()) -> inet:ip4_address()).
parse_ipv4_address(Value) when is_binary(Value) ->
    parse_ipv4_address(binary_to_list(Value));
parse_ipv4_address(Value) ->
    {ok, IP} = inet:parse_ipv4_address(Value),
    IP.

%% @doc Parse an IPv4 Address with an optionally specified port.
%% The default port will be substituted in if not given.
-spec(parse_ipv4_address_with_port(binary()|list(), inet:port_number()) -> upstream()).
parse_ipv4_address_with_port(Value, DefaultPort) ->
    case re:split(Value, ":") of
        [IP, Port] -> {parse_ipv4_address(IP), parse_port(Port)};
        [IP] -> {parse_ipv4_address(IP), DefaultPort}
    end.

-spec(parse_upstream_name(dns:dname()) -> [dns:label()]).
parse_upstream_name(Name) when is_binary(Name) ->
    LowerName = dns:dname_to_lower(Name),
    Labels = dns:dname_to_labels(LowerName),
    lists:reverse(Labels).

%%====================================================================
%% Internal functions
%%====================================================================

-spec parse_port(binary()|list()) -> inet:port_number().
parse_port(Port) when is_binary(Port) ->
    binary_to_integer(Port);
parse_port(Port) when is_list(Port) ->
    list_to_integer(Port).

-spec(maybe_start_tcp_listener() -> ok).
maybe_start_tcp_listener() ->
    case dcos_dns_config:tcp_enabled() of
        true ->
            IPs = dcos_dns_config:bind_ips(),
            lists:foreach(fun start_tcp_listener/1, IPs);
        false ->
            ok
    end.

-spec(start_tcp_listener(inet:ip4_address()) -> supervisor:startchild_ret()).
start_tcp_listener(IP) ->
    Port = dcos_dns_config:tcp_port(),
    Acceptors = 100,
    Options = [{port, Port}, {ip, IP}],
    {ok, _} = ranch:start_listener({?TCP_LISTENER_NAME, IP},
        Acceptors,
        ranch_tcp,
        Options,
        dcos_dns_tcp_handler,
        []).

-spec(maybe_start_http_listener() -> ok).
maybe_start_http_listener() ->
    case dcos_dns_config:http_enabled() of
        true ->
            IPs = dcos_dns_config:bind_ips(),
            lists:foreach(fun start_http_listener/1, IPs);
        false ->
            ok
    end.

-spec(start_http_listener(inet:ip4_address()) -> supervisor:startchild_ret()).
start_http_listener(IP) ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/v1/version", dcos_dns_http_handler, [version]},
            {"/v1/config", dcos_dns_http_handler, [config]},
            {"/v1/hosts/:host", dcos_dns_http_handler, [hosts]},
            {"/v1/services/:service", dcos_dns_http_handler, [services]},
            {"/v1/enumerate", dcos_dns_http_handler, [enumerate]},
            {"/v1/records", dcos_dns_http_handler, [records]}
        ]}
    ]),
    Port = dcos_dns_config:http_port(),
    cowboy:start_http(
        IP, 1024,
        [{port, Port}, {ip, IP}],
        [{env, [{dispatch, Dispatch}]}]
    ).

% Sample configuration:
%  {
%    "upstream_resolvers": ["169.254.169.253"],
%    "udp_port": 53,
%    "tcp_port": 53,
%    "forward_zones": [["a.contoso.com", [["1.1.1.1", 53]
%                                         ["2.2.2.2", 53]]],
%                      ["b.contoso.com", [["3.3.3.3", 53],
%                                         ["4.4.4.4", 53]]]]
%  }
maybe_load_json_config() ->
    case file:read_file("/opt/mesosphere/etc/spartan.json") of
        {ok, FileBin} ->
            load_json_config(FileBin);
        _ ->
            ok
    end.

load_json_config(FileBin) ->
    ConfigMap = jsx:decode(FileBin, [return_maps]),
    ConfigTuples = maps:to_list(ConfigMap),
    lists:foreach(fun process_config_tuple/1, ConfigTuples).

process_config_tuple({<<"upstream_resolvers">>, UpstreamResolvers}) ->
    UpstreamIPsAndPorts = lists:map(fun (Resolver) -> parse_ipv4_address_with_port(Resolver, 53) end, UpstreamResolvers),
    application:set_env(?APP, upstream_resolvers, UpstreamIPsAndPorts);
process_config_tuple({<<"forward_zones">>, Upstreams0}) ->
    Upstreams1 = lists:foldl(fun parse_upstream/2, maps:new(), Upstreams0),
    application:set_env(?APP, forward_zones, Upstreams1);
process_config_tuple({<<"bind_ips">>, IPs0}) ->
    IPs1 = lists:map(fun parse_ipv4_address/1, IPs0),
    application:set_env(?APP, bind_ips, IPs1);
process_config_tuple({<<"bind_ip_blacklist">>, IPs0}) ->
    IPs1 = lists:map(fun parse_ipv4_address/1, IPs0),
    application:set_env(?APP, bind_ip_blacklist, IPs1);
process_config_tuple({Key, Value}) when is_binary(Value) ->
    application:set_env(?APP, binary_to_atom(Key, utf8), binary_to_list(Value));
process_config_tuple({Key, Value}) ->
    application:set_env(?APP, binary_to_atom(Key, utf8), Value).

-spec(parse_upstream(ZoneDef :: [binary() | list([binary() | integer(), ...]), ...],
                     Acc :: #{[dns:label()] => [upstream()]}) -> #{[dns:label()] => [upstream()]}).
parse_upstream([Zone, Upstreams0], Acc) when is_binary(Zone), is_list(Upstreams0) ->
    Labels = parse_upstream_name(Zone),
    Upstreams1 = lists:map(fun mk_upstream/1, Upstreams0),
    maps:put(Labels, Upstreams1, Acc).

-spec(mk_upstream(Upstream :: [binary() | integer()]) -> upstream()).
mk_upstream([Server, Port]) when is_binary(Server), is_integer(Port) ->
    {parse_ipv4_address(Server), Port}.

%%====================================================================
%% Unit Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_ipv4_addres_with_port_test() ->
    %% With explicit port
    ?assert({{127, 0, 0, 1}, 9000} == parse_ipv4_address_with_port("127.0.0.1:9000", 42)),
    %% Fallback to default
    ?assert({{8, 8, 8, 8}, 12345} == parse_ipv4_address_with_port("8.8.8.8", 12345)).

parse_ipv4_address_test() ->
    ?assert({127, 0, 0, 1} == parse_ipv4_address(<<"127.0.0.1">>)),
    ?assert([{127, 0, 0, 1}, {2, 2, 2, 2}] == lists:map(fun parse_ipv4_address/1, [<<"127.0.0.1">>, <<"2.2.2.2">>])).

-endif.
