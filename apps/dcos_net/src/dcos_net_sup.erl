-module(dcos_net_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

-define(CHILD(Module), #{id => Module, start => {Module, start_link, []}}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{}, [
        ?CHILD(dcos_net_masters)
    ]}}.
