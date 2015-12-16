%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 12:49 AM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_network_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Num), {I, {I, start_link, [Num]}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Num) ->
  supervisor:start_link(?MODULE, [Num]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Num]) ->
  {ok,
   { {one_for_one, 5, 10},
     [
       ?CHILD(dcos_l4lb_ct, worker, Num),
       ?CHILD(dcos_l4lb_packet_handler, worker, Num),
       ?CHILD(dcos_l4lb_nfq, worker, Num)
     ]} }.


