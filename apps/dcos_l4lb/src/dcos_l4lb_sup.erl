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


maybe_add_network_child(Children) ->
    case dcos_l4lb_config:networking() of
        true ->
            [?CHILD(dcos_l4lb_network_sup_sup, supervisor)|Children];
        false ->
            Children
    end.
add_default_children(Children) ->
    [
        ?CHILD(dcos_l4lb_vip_events, worker),
        ?CHILD(dcos_l4lb_ipsets, worker),
        ?CHILD(dcos_l4lb_vip_server, worker),
        ?CHILD(dcos_l4lb_mesos_poller, worker)|
        Children
    ].
get_children() ->
    Children1 = maybe_add_network_child([]),
    Children2 = add_default_children(Children1),
    Children2.

init([]) ->
    {ok, { {one_for_one, 5, 10}, get_children()} }.

