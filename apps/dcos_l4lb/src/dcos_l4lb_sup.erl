-module(dcos_l4lb_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

-define(CHILD(Module), #{id => Module, start => {Module, start_link, []}}).
-define(CHILD(Module, Custom), maps:merge(?CHILD(Module), Custom)).

start_link([Enabled]) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Enabled]).

init([false]) ->
    {ok, {#{}, []}};
init([true]) ->
    dcos_l4lb_mesos_poller:init_metrics(),
    {ok, {#{intensity => 10000, period => 1}, [
        ?CHILD(dcos_l4lb_network_sup, #{type => supervisor}),
        ?CHILD(dcos_l4lb_mesos_poller),
        ?CHILD(dcos_l4lb_metrics),
        ?CHILD(dcos_l4lb_lashup_publish)
    ]}}.
