%%-------------------------------------------------------------------
%% @author dgoel
%% @copyright (C) 2017, <COMPANY>
%% @doc
%% Polls K8s apiserver if {dcos_l4lb, agent_polling_enabled} is true
%%
%% @end
%% Created : 25 Oct 2017 9:14 AM
%%-------------------------------------------------------------------

-module(dcos_l4lb_k8s_poller).
-author("dgoel").

-behaviour(gen_server).

%% API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-include("dcos_l4lb.hrl").
-include("dcos_l4lb_lashup.hrl").

-record(state, {
    agent_ip = erlang:error() :: inet:ip4_address(),
    uri = [] :: list(),
    last_poll_time = undefined :: integer() | undefined
}).

-define(WAIT, 5). %% in secs

-type protocol() :: tcp | udp.
-type vip_string() :: {name, {binary(), binary()}}.


-record(vip_be2, {
    protocol = erlang:error() :: protocol(),
    vip_ip = erlang:error() :: inet:ip_address() | vip_string(),
    vip_port = erlang:error() :: inet:port_number(),
    agent_ip = erlang:error() :: inet:ip4_address(),
    backend_ip = erlang:error() :: inet:ip_address(),
    backend_port = erlang:error() :: inet:port_number()
}).

-type vip_be2() :: #vip_be2{}.
-type protocol_vip() :: {protocol(), Host :: inet:ip_address() | string(), inet:port_number()}.
-type protocol_vip_orswot() :: {protocol_vip(), riak_dt_orswot}.

start() ->
    case dcos_l4lb_k8s_sup:start_child([]) of
        {ok, Pid} ->
            {ok, Pid};
        Error ->
            lager:error("couldn't start K8s poller ~p", [Error]),
            error
    end.

%%===================================================================
%% API
%%===================================================================
%%
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%===================================================================
%% gen_server callbacks
%%===================================================================
init([]) ->
    erlang:send_after(?WAIT, self(), maybe_poll),
    AgentIP = mesos_state:ip(),
    URI = "http://apiserver-insecure.kubernetes.l4lb.thisdcos.directory:9000",
    {ok, #state{agent_ip = AgentIP, uri = URI}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(maybe_poll, State = #state{agent_ip = AgentIP}) ->
    NewState = case check_lashup() of
                   AgentIP  ->
                       lager:error("Finally polling"),
                       poll(State);
                   _ ->
                       lager:error("I am not polling :("),
                       {stop, normal, state}
               end,
    PollInterval = dcos_l4lb_config:agent_poll_interval(),
    erlang:send_after(PollInterval, self(), maybe_poll),
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal functions
%%===================================================================
check_lashup() ->
    KubeMetaData = lashup_kv:value(?KUBEMETADATA_KEY),
    KubeMetaDataList = orddict:from_list(KubeMetaData),
    case orddict:find(?LWW_REG(?KUBEAPIKEY), KubeMetaDataList) of
        {ok, AgentIP} -> AgentIP;
        Else -> Else
    end.

poll(State = #state{uri = URI}) ->
    Path = "api/v1/services",
    case dcos_l4lb_k8s_client:get(URI, Path) of
        {error, Reason} ->
            lager:warning("Unable to fetch ~p from K8s apiserver ~p due to ~p", [Path, URI, Reason]),
            State;
        {ok, Response} ->
            handle_poll(Response, State)
    end.

handle_poll(Response, State) ->
    VIPBEs = collect_vips(Response, State),
    handle_poll_changes(VIPBEs, State#state.agent_ip),
    State#state{last_poll_time = erlang:monotonic_time()}.

-spec(handle_poll_changes([vip_be2()], inet:ip4_address()) -> ok | {ok, _}).
handle_poll_changes(VIPBEs, AgentIP) ->
    LashupVIPs = lashup_kv:value(?VIPS_KEY2),
    Ops = generate_ops(AgentIP, VIPBEs, LashupVIPs),
    maybe_perform_ops(?VIPS_KEY2, Ops).

maybe_perform_ops(_, []) ->
    ok;
maybe_perform_ops(Key, Ops) ->
    lager:debug("Performing Key: ~p, Ops: ~p", [Key, Ops]),
    {ok, _} = lashup_kv:request_op(Key, {update, Ops}).

generate_ops(AgentIP, AgentVIPs, LashupVIPs) ->
    lists:reverse(generate_ops1(AgentIP, AgentVIPs, LashupVIPs)).

generate_ops1(AgentIP, AgentVIPs, LashupVIPs) ->
    FlatAgentVIPs = flatten_vips(AgentVIPs),
    FlatLashupVIPs = flatten_vips(LashupVIPs),
    FlatVIPsToAdd = ordsets:subtract(FlatAgentVIPs, FlatLashupVIPs),
    FlatLashupVIPsFromThisAgent = filter_vips_from_agent(AgentIP, FlatLashupVIPs),
    FlatVIPsToDel = ordsets:subtract(FlatLashupVIPsFromThisAgent, FlatAgentVIPs),
    Ops0 = lists:foldl(fun flat_vip_add_fold/2, [], FlatVIPsToAdd),
    Ops1 = lists:foldl(fun flat_vip_del_fold/2, Ops0, FlatVIPsToDel),
    add_cleanup_ops(FlatLashupVIPs, FlatVIPsToDel, Ops1).

filter_vips_from_agent(AgentIP, FlatLashupVIPs) ->
    lists:filter(fun(#vip_be2{agent_ip = AIP}) -> AIP == AgentIP end, FlatLashupVIPs).

add_cleanup_ops(FlatLashupVIPs, FlatVIPsToDel, Ops0) ->
    ExistingProtocolVIPs = lists:map(fun to_protocol_vip/1, FlatLashupVIPs),
    FlatRemainingVIPs = ordsets:subtract(FlatLashupVIPs, FlatVIPsToDel),
    RemainingProtocolVIPs =  lists:map(fun to_protocol_vip/1, FlatRemainingVIPs),
    GCVIPs = ordsets:subtract(ordsets:from_list(ExistingProtocolVIPs), ordsets:from_list(RemainingProtocolVIPs)),
    lists:foldl(fun flat_vip_gc_fold/2, Ops0, GCVIPs).

flat_vip_gc_fold(VIP, Acc) ->
    Field = {VIP, riak_dt_orswot},
    Op = {remove, Field},
    [Op | Acc].

flat_vip_add_fold(VIPBE = #vip_be2{agent_ip = AgentIP, backend_ip = BEIP, backend_port = BEPort}, Acc) ->
    Field = {to_protocol_vip(VIPBE), riak_dt_orswot},
    Op = {update, Field, {add, {AgentIP, {BEIP, BEPort}}}},
    [Op | Acc].

flat_vip_del_fold(VIPBE = #vip_be2{agent_ip = AgentIP, backend_ip = BEIP, backend_port = BEPort}, Acc) ->
    Field = {to_protocol_vip(VIPBE), riak_dt_orswot},
    Op = {update, Field, {remove, {AgentIP, {BEIP, BEPort}}}},
    [Op | Acc].

-spec(to_protocol_vip(vip_be2()) -> protocol_vip()).
to_protocol_vip(#vip_be2{vip_ip = VIPIP, protocol = Protocol, vip_port = VIPPort}) ->
    {Protocol, VIPIP, VIPPort}.

-spec(flatten_vips([{VIP :: protocol_vip() | protocol_vip_orswot(), [Backend :: ip_ip_port()]}]) -> [vip_be2()]).
flatten_vips(VIPDict) ->
    VIPBEs =
        lists:flatmap(
            fun
                ({{{Protocol, VIPIP, VIPPort}, riak_dt_orswot}, Backends}) ->
                    [#vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = BEPort,
                        backend_ip =  BEIP, agent_ip = AgentIP} || {AgentIP, {BEIP, BEPort}} <- Backends];
                ({{Protocol, VIPIP, VIPPort}, Backends}) ->
                    [#vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = BEPort,
                        backend_ip =  BEIP, agent_ip = AgentIP} || {AgentIP, {BEIP, BEPort}} <- Backends]
            end,
            VIPDict
        ),
    ordsets:from_list(VIPBEs).

-spec(unflatten_vips([vip_be2()]) -> [{VIP :: protocol_vip(), [Backend :: ip_ip_port()]}]).
unflatten_vips(VIPBes) ->
    VIPBEsDict =
        lists:foldl(
            fun(#vip_be2{vip_ip = VIPIP, vip_port = VIPPort, protocol = Protocol, backend_port = BEPort,
                    backend_ip = BEIP, agent_ip = AgentIP},
                Acc) ->
                orddict:append({Protocol, VIPIP, VIPPort}, {AgentIP, {BEIP, BEPort}}, Acc)
            end,
            orddict:new(),
            VIPBes
        ),
    orddict:map(fun(_Key, Value) -> ordsets:from_list(Value) end, VIPBEsDict).

collect_vips(Response, State) ->
    Services0 = maps:get(<<"items">>, Response),
    Services1 = lists:filter(
                   fun
                     (#{<<"spec">> := #{<<"type">> := <<"LoadBalancer">>}}) ->
                         true;
                     (_) ->
                         false
                   end, Services0),
    VIPBEs0 = collect_vips_from_services(Services1, ordsets:new(), State),
    VIPBEs1 = lists:usort(VIPBEs0),
    unflatten_vips(VIPBEs1).

collect_vips_from_services([], VIPBEs, _State) ->
    VIPBEs;
collect_vips_from_services([Service | Services], VIPBEs, State) ->
    VIPBEs1 =
        case catch collect_vips_from_service(Service, State) of
            {'EXIT', Reason} ->
                lager:warning("Failed to parse task (labels): ~p", [Reason]),
                VIPBEs;
            AdditionalVIPBEs ->
                ordsets:union(ordsets:from_list(AdditionalVIPBEs), VIPBEs)
        end,
    collect_vips_from_services(Services, VIPBEs1, State).

collect_vips_from_service(#{<<"metadata">> := Metadata, <<"spec">> := Spec},
  #state{agent_ip = AgentIP, uri = URI}) ->
    #{<<"name">> := Name, <<"namespace">> := NameSpace} = Metadata,
    #{<<"ports">> := Ports, <<"selector">> := Selector} = Spec,
    [#{<<"port">> := VIPPort, <<"protocol">> := ProtoBin, <<"targetPort">> := BePort} | _] = Ports,
    VIP = {name, {<<Name/binary, ".", NameSpace/binary>>, <<"Kubernetes">>}},
    Proto = list_to_atom(string:to_lower(binary_to_list(ProtoBin))),
    BEs = fetch_BE_from_pods(URI, Selector),
    [#vip_be2{vip_ip = VIP, vip_port = VIPPort, protocol = Proto, backend_port = BePort,
        backend_ip =  BE, agent_ip = AgentIP} || BE <- BEs].

fetch_BE_from_pods(URI, Selector) ->
    Pods0 = fetch_pods(URI, Selector),
    Pods1 = filter_pods_by_status(Pods0),
    BEs = [inet:parse_address(binary_to_list(BE)) ||
              #{<<"status">> := #{<<"podIP">> := BE}} <- Pods1],
    lists:filtermap(
        fun({ok, BE}) -> {true, BE};
           (_)  -> false
        end, BEs).

fetch_pods(URI, Selector) ->
    Path = "api/v1/pods",
    SelectorKeys = maps:keys(Selector),
    QueryParams0 = [string:join([binary_to_list(Key), binary_to_list(maps:get(Key, Selector))], "=")
                    || Key <- SelectorKeys],
    QueryParams1 = string:join(QueryParams0, ","),
    QueryParams2 = string:join(["labelSelector", QueryParams1], "="),
    case dcos_l4lb_k8s_client:get(URI, Path, QueryParams2) of
        {error, Reason} ->
            lager:warning("Unable to fetch _~p from K8s apiserver ~p due to ~p", [Path, URI, Reason]),
            [];
         {ok, Response} ->
            maps:get(<<"items">>, Response)
    end.

filter_pods_by_status(Pods) ->
    lists:filter(
        fun
            (#{<<"status">> := #{<<"containerStatuses">> := [#{<<"state">> := #{<<"running">> := _}}|_]}}) ->
                true;
            (_) ->
                false
        end, Pods).
