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
-export([exhibitor_timeout/0, udp_enabled/0, tcp_enabled/0, tcp_port/0, udp_port/0, bind_interface/0, bind_ips/0, forward_zones/0]).
exhibitor_timeout() ->
    application:get_env(?APP, exhibitor_timeout, ?EXHIBITOR_TIMEOUT).

udp_enabled() ->
    application:get_env(?APP, udp_server_enabled, true).

tcp_enabled() ->
    application:get_env(?APP, tcp_server_enabled, true).

tcp_port() ->
    application:get_env(?APP, tcp_port, 5454).

udp_port() ->
    application:get_env(?APP, udp_port, 5454).

-spec(forward_zones() -> #{[dns:label()] => [{string(), integer()}]}).
forward_zones() ->
    application:get_env(?APP, forward_zones, maps:new()).

bind_interface() ->
    application:get_env(?APP, bind_interface, undefined).

-spec(bind_ips() -> [inet:ip4_address()]).
bind_ips() ->
    IPs0 = case application:get_env(?APP, bind_ips, []) of
        [] ->
            DefaultIps = get_ips(),
            application:set_env(?APP, bind_ips, DefaultIps),
            DefaultIps;
        V ->
            V
    end,
    lager:debug("found ips: ~p", [IPs0]),
    BlacklistedIPs = application:get_env(?APP, bind_ip_blacklist, []),
    lager:debug("blacklist ips: ~p", [BlacklistedIPs]),
    IPs1 = [ IP || IP <- IPs0, not lists:member(IP, BlacklistedIPs) ],
    IPs2 = lists:usort(IPs1),
    lager:debug("final ips: ~p", [IPs2]),
    IPs2.

-spec(get_ips() -> [inet:ip4_address()]).
get_ips() ->
    IFs0 = get_ip_interfaces(),
    IPs = case bind_interface() of
        undefined ->
            [Addr || {_IfName, Addr} <- IFs0];
        ConfigInterfaceName ->
            IFs1 = lists:filter(fun({IfName, _Addr}) -> string:equal(IfName, ConfigInterfaceName) end, IFs0),
            [Addr || {_IfName, Addr} <- IFs1]
    end,
    lists:usort(IPs).

%% @doc Gets all the IPs for the machine
-spec(get_ip_interfaces() -> [{InterfaceName :: string(), inet:ip4_address()}]).
get_ip_interfaces() ->
    %% The list comprehension makes it so we only get IPv4 addresses
    {ok, Iflist} = inet:getifaddrs(),
    lists:foldl(fun fold_over_if/2, [], Iflist).

fold_over_if({IfName, IfOpts}, Acc) ->
    IfAddresses = [{IfName, Address} || {addr, Address = {_, _, _, _}} <- IfOpts],
    ordsets:union(ordsets:from_list(IfAddresses), Acc).
