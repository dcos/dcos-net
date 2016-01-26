%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. Jan 2016 9:53 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_wm).
-author("sdhillon").

%% API
-export([start/0]).

dispatch() ->
  lists:flatten([
    {["metrics"], dcos_l4lb_api, []},
    {["vips"], dcos_l4lb_api, []},
    {["vip", vip], dcos_l4lb_api, []},
    {["backend", backend], dcos_l4lb_api, []},
    {["lashup", '*'], dcos_l4lb_wm_lashup, []},
    {['*'], dcos_l4lb_wm_home, []}
  ]).


start() ->
  Dispatch = dispatch(),
  ApiConfig = [
    {ip, dcos_l4lb_config:api_listen_ip()},
    {port, dcos_l4lb_config:api_listen_port()},
    {log_dir, "priv/log"},
    {dispatch, Dispatch}
  ],
  webmachine_mochiweb:start(ApiConfig).
