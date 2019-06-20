-module(dcos_l4lb_network_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

-define(CHILD(Module), #{id => Module, start => {Module, start_link, []}}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    dcos_l4lb_mgr:init_metrics(),
    {ok, {#{strategy => rest_for_one},
        [?CHILD(dcos_l4lb_mgr) || dcos_l4lb_config:networking()] ++
        [?CHILD(dcos_l4lb_lashup_vip_listener)]
    }}.
