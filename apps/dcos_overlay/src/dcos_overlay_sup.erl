%%%-------------------------------------------------------------------
%% @doc navstar top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(dcos_overlay_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).


%% API
-export([]).
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
        ?CHILD(dcos_overlay_poller, worker),
        ?CHILD(dcos_overlay_lashup_kv_listener, worker)
    ].

init([Enabled]) ->
    {ok, {#{
        strategy => rest_for_one,
        intensity => 10000,
        period => 1
    }, get_children(Enabled)}}.
