-module(dcos_net_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

-define(CHILD(Module), #{id => Module, start => {Module, start_link, []}}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    dcos_net_mesos:init_metrics(),
    dcos_net_mesos_listener:init_metrics(),
    dcos_net_logger_h:add_handler(),
    dcos_net_vm_metrics_collector:init(),
    IsMaster = dcos_net_app:is_master(),
    MChildren = [?CHILD(dcos_net_mesos_listener) || IsMaster],
    {ok, {#{intensity => 10000, period => 1}, [
        ?CHILD(dcos_net_masters),
        ?CHILD(dcos_net_killer),
        ?CHILD(dcos_net_node) | MChildren
    ]}}.
