-module(dcos_dns_app).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(application).

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

%% Application callbacks
-export([start/2, stop/1, wait_for_reqid/2]).

%% API
-export([parse_ipv4_address/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    maybe_load_json_config(), %% Maybe load the relevant DCOS configuration
    Ret = dcos_dns_sup:start_link(),
    maybe_start_tcp_listener(),
    Ret.

%%--------------------------------------------------------------------
stop(_State) ->
    ranch:stop_listener(?TCP_LISTENER_NAME),
    ok.


%% @doc Parse an IP Address
parse_ipv4_address(Value) when is_binary(Value) ->
    parse_ipv4_address(binary_to_list(Value));
parse_ipv4_address(Value) ->
    {ok, IP} = inet:parse_ipv4_address(Value),
    IP.

%%====================================================================
%% Internal functions
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

%% @private
maybe_start_tcp_listener() ->
    case application:get_env(?APP, tcp_server_enabled, true) of
        true ->
            Port = application:get_env(?APP, tcp_port, 5454),
            Acceptors = 100,
            Options = [{port, Port}],
            {ok, _} = ranch:start_listener(?TCP_LISTENER_NAME,
                                           Acceptors,
                                           ranch_tcp,
                                           Options,
                                           dcos_dns_tcp_handler,
                                           []);
        false ->
            ok
    end.

% A normal configuration would look something like:
%{
%   "upstream_resolvers": ["169.254.169.253"],
%   "udp_port": 53,
%   "tcp_port": 53
%}

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
    UpstreamResolverIPs = lists:map(fun parse_ipv4_address/1, UpstreamResolvers),
    ConfigValue = [{UpstreamResolverIP, 53} || UpstreamResolverIP <- UpstreamResolverIPs],
    application:set_env(?APP, upstream_resolvers, ConfigValue);
process_config_tuple({Key, Value}) ->
    application:set_env(?APP, binary_to_atom(Key, utf8), Value).


