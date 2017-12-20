%%%-------------------------------------------------------------------
%%% @author dgoel
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. Dec 2017 3:56 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_k8s_sup).
-author("dgoel").

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_child/1,
         terminate_child/2]).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a child.
start_child(Args) ->
    supervisor:start_child(?MODULE, Args).

%% @doc Stop a child immediately
terminate_child(Supervisor, Pid) ->
    supervisor:terminate_child(Supervisor, Pid).


init([]) ->
  {ok, { {simple_one_for_one, 10, 10}, [?CHILD(dcos_l4lb_k8s_poller, worker)]} }.

