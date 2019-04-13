%%%-------------------------------------------------------------------
%%% @author sdhillon, Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 8:58 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_config).
-author("sdhillon").
-author("Tyler Neely").

%% API
-export([
  agent_poll_interval/0,
  networking/0,
  agent_polling_enabled/0,
  min_named_ip/0,
  max_named_ip/0,
  ipv6_enabled/0,
  min_named_ip6/0,
  max_named_ip6/0,
  ipset_enabled/0,
  dcos_l4lb_iface/0,
  metrics_interval_seconds/0,
  metrics_splay_seconds/0,
  cni_dir/0
  ]).

metrics_interval_seconds() ->
  application:get_env(dcos_l4lb, metrics_interval_seconds, 20).

metrics_splay_seconds() ->
  application:get_env(dcos_l4lb, metrics_interval_seconds, 2).

dcos_l4lb_iface() ->
  application:get_env(dcos_l4lb, iface, "minuteman").

agent_poll_interval() ->
  application:get_env(dcos_l4lb, agent_poll_interval, 2000).

networking() ->
  application:get_env(dcos_l4lb, enable_networking, true).

agent_polling_enabled() ->
  application:get_env(dcos_l4lb, agent_polling_enabled, true).

cni_dir() ->
  application:get_env(dcos_l4lb, cni_dir, "/var/run/dcos/cni/l4lb").

-spec(min_named_ip() -> inet:ip4_address()).
min_named_ip() ->
  application:get_env(dcos_l4lb, min_named_ip, {11, 0, 0, 0}).

-spec(max_named_ip() -> inet:ip4_address()).
-ifndef(TEST).
max_named_ip() ->
  application:get_env(dcos_l4lb, max_named_ip, {11, 255, 255, 254}).
-else.
max_named_ip() ->
  application:get_env(dcos_l4lb, max_named_ip, {11, 0, 0, 254}).
-endif.

ipv6_enabled() ->
  application:get_env(dcos_l4lb, enable_ipv6, true).

min_named_ip6() ->
  application:get_env(dcos_l4lb, min_named_ip6, {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#0}).

max_named_ip6() ->
  application:get_env(dcos_l4lb, max_named_ip6, {16#fd01, 16#c, 16#0, 16#0, 16#ffff, 16#ffff, 16#ffff, 16#ffff}).

ipset_enabled() ->
  application:get_env(dcos_l4lb, ipset_enabled, true).
