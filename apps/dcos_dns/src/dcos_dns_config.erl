%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Apr 2016 5:02 PM
%%%-------------------------------------------------------------------
-module(dcos_dns_config).
-author("Sargun Dhillon <sargun@mesosphere.com>").

-include("dcos_dns.hrl").

%% API
-export([udp_enabled/0, tcp_enabled/0, tcp_port/0, udp_port/0, bind_interface/0, bind_ips/0]).
udp_enabled() ->
    application:get_env(?APP, udp_server_enabled, true).

tcp_enabled() ->
    application:get_env(?APP, tcp_server_enabled, true).

tcp_port() ->
    application:get_env(?APP, tcp_port, 5454).

udp_port() ->
    application:get_env(?APP, udp_port, 5454).

bind_interface() ->
    application:get_env(?APP, bind_interface, undefined).

bind_ips() ->
    case application:get_env(?APP, bind_ips, []) of
        [] ->
            IPs = bind_ips2(),
            application:set_env(?APP, bind_ips, IPs),
            IPs;
        IPs ->
            IPs
    end.

bind_ips2() ->
    IFs0 = get_ip_interfaces(),
    case bind_interface() of
        undefined ->
            [Addr || {_IfName, Addr} <- IFs0];
        ConfigInterfaceName ->
            IFs1 = lists:filter(fun({IfName, _Addr}) -> string:equal(IfName, ConfigInterfaceName) end, IFs0),
            [Addr || {_IfName, Addr} <- IFs1]
    end.

%% @doc Gets all the IPs for the machine
-spec(get_ip_interfaces() -> [{InterfaceName :: string(), inet:ipv4_address()}]).
get_ip_interfaces() ->
    %% The list comprehension makes it so we only get IPv4 addresses
    {ok, Iflist} = inet:getifaddrs(),
    lists:foldl(fun fold_over_if/2, [], Iflist).

fold_over_if({IfName, IfOpts}, Acc) ->
    IfAddresses = [{IfName, Address} || {addr, Address = {_, _, _, _}} <- IfOpts],
    ordsets:union(ordsets:from_list(IfAddresses), Acc).