-module(dcos_net_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

-define(CHILD(Module), #{id => Module, start => {Module, start_link, []}}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    case application:get_env(dcos_net, epmd_port) of
        {ok, Port} -> start_epmd(Port);
        undefined -> ok
    end,

    IsMaster = dcos_net_app:is_master(),
    MChildren = [?CHILD(dcos_net_mesos_listener) || IsMaster],
    {ok, {#{intensity => 10000, period => 1}, [
        ?CHILD(dcos_net_masters),
        ?CHILD(dcos_net_statsd)
        | MChildren
    ]}}.

start_epmd(Port) ->
    [_Name, Host] = string:tokens(atom_to_list(node()), "@"),
    {ok, IP} = inet:parse_ipv4strict_address(Host),
    case ranch:start_listener(
            dcos_net_epmd, 10, ranch_tcp,
            [{port, Port}, {ip, IP}], dcos_net_epmd, []) of
        {ok, _Pid} ->
            ok;
        {error, Error} ->
            lager:error("Couldn't start epmd: ~p", [Error]),
            erlang:halt(1)
    end.
