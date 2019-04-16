-module(dcos_l4lb_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link([Enabled]) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Enabled]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
get_children(false) ->
    [];
get_children(true) ->
    [
        ?CHILD(dcos_l4lb_network_sup, supervisor),
        ?CHILD(dcos_l4lb_mesos_poller, worker),
        ?CHILD(dcos_l4lb_metrics, worker),
        ?CHILD(dcos_l4lb_lashup_publish, worker)
    ].

init([Enabled]) ->
    dcos_l4lb_mesos_poller:init_metrics(),
    dcos_l4lb_mgr:init_metrics(),
    {ok, {#{intensity => 10000, period => 1}, get_children(Enabled)}}.

