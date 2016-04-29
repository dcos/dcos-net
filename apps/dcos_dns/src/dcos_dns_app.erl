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
-export([parse_ipv4_address/1, bind_ips/0]).

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

%% @doc Gets the IPs to bind to
bind_ips() ->
    IFs0 = get_ip_interfaces(),
    case dcos_dns_config:bind_interface() of
        undefined ->
            [Addr || {_IfName, Addr} <- IFs0];
        ConfigInterfaceName ->
            IFs1 = lists:filter(fun({IfName, _Addr}) -> string:equal(IfName, ConfigInterfaceName) end, IFs0),
            [Addr || {_IfName, Addr} <- IFs1]
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%% @doc Gets all the IPs for the machine
-spec(get_ip_interfaces() -> [{InterfaceName :: string(), inet:ipv4_address()}]).
get_ip_interfaces() ->
    %% The list comprehension makes it so we only get IPv4 addresses
    {ok, Iflist} = inet:getifaddrs(),
    lists:foldl(fun fold_over_if/2, [], Iflist).

fold_over_if({IfName, IfOpts}, Acc) ->
    IfAddresses = [{IfName, Address} || {addr, Address = {_, _, _, _}} <- IfOpts],
    ordsets:union(ordsets:from_list(IfAddresses), Acc).

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
    case dcos_dns_config:tcp_enabled() of
        true ->
            IPs = dcos_dns_app:bind_ips(),
            lists:foreach(fun start_tcp_listener/1, IPs);
        false ->
            ok
    end.

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
process_config_tuple({Key, Value}) when is_binary(Value) ->
    application:set_env(?APP, binary_to_atom(Key, utf8), binary_to_list(Value));
process_config_tuple({Key, Value}) ->
    application:set_env(?APP, binary_to_atom(Key, utf8), Value).


