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
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
  {ok,
   { {one_for_one, 5, 10},
     [?CHILD(dcos_l4lb_ct, worker),
      ?CHILD(dcos_l4lb_packet_handler, worker),
      ?CHILD(dcos_l4lb_nfq, worker)]} }.
