-module(dcos_net_masters).
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-record(state, {
    ref :: reference()
}).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Ref = erlang:start_timer(0, self(), poll),
    {ok, #state{ref=Ref}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({timeout, Ref, poll}, State = #state{ref = Ref}) ->
    MesosResolvers = dcos_dns_config:mesos_resolvers(),
    ok = update_masters(MesosResolvers),
    Timeout = application:get_env(dcos_net, update_masters_timeout, 5000),
    Ref0 = erlang:start_timer(Timeout, self(), poll),
    {noreply, State#state{ref=Ref0}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

update_masters([]) ->
    ok;
update_masters(MesosResolvers) ->
    Nodes = lists:map(fun resolver_to_node/1, MesosResolvers),
    Nodes0 = lists:delete(node(), Nodes),
    telemetry_config:forwarder_destinations(Nodes),
    lashup_hyparview_membership:update_masters(Nodes0).

resolver_to_node({IP, _Port}) ->
    NodePrefix = node_name(),
    Node = lists:flatten([NodePrefix, "@", inet:ntoa(IP)]),
    list_to_atom(Node).

node_name() ->
    Node = atom_to_list(node()),
    [NodeName, _Host] = string:tokens(Node, "@"),
    NodeName.
