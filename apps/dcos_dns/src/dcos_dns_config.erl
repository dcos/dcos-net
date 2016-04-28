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
-export([udp_enabled/0, tcp_enabled/0, tcp_port/0, udp_port/0, bind_interface/0]).
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
