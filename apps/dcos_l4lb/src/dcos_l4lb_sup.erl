-module(dcos_l4lb_sup).

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

get_children() ->
    [
        ?CHILD(dcos_l4lb_network_sup, supervisor),
        ?CHILD(dcos_l4lb_mesos_poller, worker),
        ?CHILD(dcos_l4lb_lashup_publish, worker),
        ?CHILD(dcos_l4lb_lashup_index, worker)
    ].

init([]) ->
    {ok, { {one_for_one, 5, 10}, get_children()} }.

