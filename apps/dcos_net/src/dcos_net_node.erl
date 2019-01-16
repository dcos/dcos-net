-module(dcos_net_node).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    get_metadata/0,
    get_metadata/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-export_type([metadata/0]).

-type metadata() :: #{
    public_ips => [inet:ip_address()],
    hostname => binary(),
    updated => non_neg_integer()
}.

-record(state, {
    timer_ref :: reference(),
    lashup_ref :: reference(),
    refresh = #{} :: map()
}).
-type state() :: #state{}.

-include_lib("stdlib/include/ms_transform.hrl").
-define(LASHUP_KEY, [dcos_net, nodes]).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec(get_metadata() -> #{inet:ip4_address() => metadata()}).
get_metadata() ->
    List = lashup_kv:value(?LASHUP_KEY),
    dump(List).

-spec(get_metadata(proplists:proplist()) -> #{inet:ip4_address() => metadata()}).
get_metadata([]) ->
    get_metadata();
get_metadata([force_refresh]) ->
    % It's not possible to unsubscribe from lashup_kv_events_helper's updates.
    % force_dump/0 function starts a new process that does all the work, sends
    % the result back and terminates itself.
    % TODO: Add unsubscribe to the events helper and get rid of spawn_link.
    Ref = make_ref(),
    PPid = self(),
    proc_lib:spawn_link(fun() -> force_refresh(PPid, Ref) end),
    Timeout = force_refresh_timeout(),
    receive
        {Ref, Result} ->
            Result
    after Timeout ->
        exit(timeout)
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! init,
    {ok, []}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, []) ->
    LRef = subscribe(),
    RTerm = get_refresh_value(),
    TRef = start_update_timer(0),
    {noreply, #state{timer_ref=TRef, lashup_ref = LRef, refresh = RTerm}};
handle_info({timeout, TRef, update}, State = #state{timer_ref = TRef}) ->
    ok = update_node_info(),
    TRef0 = start_update_timer(),
    {noreply, State#state{timer_ref=TRef0}, hibernate};
handle_info({lashup_kv_events, #{ref := Ref, value := Value}},
            State = #state{lashup_ref = Ref}) ->
    {noreply, handle_kv_event(Value, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_update_timer() -> reference()).
start_update_timer() ->
    Timeout = application:get_env(
        dcos_net, update_node_info, timer:minutes(30)),
    start_update_timer(Timeout).

-spec(start_update_timer(timeout()) -> reference()).
start_update_timer(Timeout) ->
    erlang:start_timer(Timeout, self(), update).

-spec(start_update_timer(reference(), timeout()) -> reference()).
start_update_timer(TRef, Timeout) ->
    erlang:cancel_timer(TRef),
    start_update_timer(Timeout).

-spec(update_node_info() -> ok).
update_node_info() ->
    Updated = erlang:system_time(millisecond),
    Key = dcos_net_dist:nodeip(),
    Value = #{
        public_ips => get_public_ips(),
        hostname => get_hostname(),
        updated => Updated
    },
    ok = update_node_info(Key, Value),
    ok = push_dns_records(Key, Value).

-spec(update_node_info(inet:ip4_address(), metadata()) -> ok).
update_node_info(Key, Value) ->
    OldList = lashup_kv:value(?LASHUP_KEY),

    LKey = {Key, riak_dt_lwwreg},
    Op = {assign, Value, maps:get(updated, Value)},
    {ok, _Info} = lashup_kv:request_op(
        ?LASHUP_KEY,
        {update, [{update, LKey, Op}]}),

    case lists:keyfind(LKey, 1, OldList) of
        {LKey, OldValue} ->
            OldValue0 = maps:remove(updated, OldValue),
            case maps:remove(updated, Value) of
                OldValue0 ->
                    ok;
                _Value0 ->
                    ok = lager:notice("Node metadata was updated: ~p", [Value])
            end;
        false ->
            ok = lager:notice("Node metadata was added: ~p", [Value])
    end.

-spec(get_public_ips() -> [inet:ip_address()]).
get_public_ips() ->
    Script = application:get_env(
        dcos_net, detect_ip_public,
        <<"/opt/mesosphere/bin/detect_ip_public">>),
    case dcos_net_utils:system([Script]) of
        {ok, Data} ->
            get_public_ips(Data);
        {error, enoent} ->
            [];
        {error, Error} ->
            lager:error(
                "~s failed to detect public ip addresses, ~p",
                [Script, Error]),
            []
    end.

-spec(get_public_ips(binary()) -> [inet:ip_address()]).
get_public_ips(Data) ->
    Lines = binary:split(Data, <<"\n">>, [global]),
    Lines0 = [Line || Line <- Lines, Line =/= <<>>],
    lists:flatmap(fun (Line) ->
        LineStr = binary_to_list(Line),
        case inet:parse_strict_address(LineStr) of
            {error, einval} -> [];
            {ok, IP} -> [IP]
        end
    end, Lines0).

-spec(get_hostname() -> binary()).
get_hostname() ->
    {ok, Str} = inet:gethostname(),
    list_to_binary(Str).

-spec(dump([{term(), term()}]) -> #{inet:ip4_address() => metadata()}).
dump(List) ->
    List0 = [{IP, Info} || {{IP, riak_dt_lwwreg}, Info} <- List, is_tuple(IP)],
    maps:from_list(List0).

%%%===================================================================
%%% Force dump functions
%%%===================================================================

-spec(handle_kv_event([{term(), term()}], state()) -> state()).
handle_kv_event(List, State = #state{timer_ref = TRef, refresh = RTerm}) ->
    % Refresh node information if `refresh` value is updated.
    case get_refresh_value(List) of
        RTerm ->
            State;
        RTerm0 ->
            TRef0 = start_update_timer(TRef, 0),
            State#state{timer_ref=TRef0, refresh=RTerm0}
    end.

-spec(get_refresh_value() -> map()).
get_refresh_value() ->
    List = lashup_kv:value(?LASHUP_KEY),
    get_refresh_value(List).

-spec(get_refresh_value([{term(), term()}]) -> map()).
get_refresh_value(List) ->
    case lists:keyfind({refresh, riak_dt_lwwreg}, 1, List) of
        {{refresh, riak_dt_lwwreg}, RTerm} ->
            RTerm;
        false ->
            #{}
    end.

-spec(force_refresh(pid(), reference()) -> ok).
force_refresh(Pid, PRef) ->
    Ref = subscribe(),

    Updated = erlang:system_time(millisecond),
    Op = {assign, #{node => node(), updated => Updated}, Updated},
    {ok, List} = lashup_kv:request_op(
        ?LASHUP_KEY,
        {update, [{update, {refresh, riak_dt_lwwreg}, Op}]}),

    % Wait till all reachable nodes update their metadata.
    Nodes = dump(List),
    Result = wait_for_refresh(Ref, Nodes),
    Pid ! {PRef, Result},
    ok.

-spec(subscribe() -> reference()).
subscribe() ->
    MatchSpec = ets:fun2ms(fun({?LASHUP_KEY}) -> true end),
    {ok, Ref} = lashup_kv_events_helper:start_link(MatchSpec),
    Ref.

-spec(wait_for_refresh(reference(), Nodes) -> Nodes
    when Nodes :: #{inet:ip4_address() => metadata()}).
wait_for_refresh(Ref, Nodes) ->
    StartTime = erlang:monotonic_time(millisecond),
    Wait = maps:with(reachable_nodes(), Nodes),
    wait_for_refresh(StartTime, Ref, Nodes, Wait).

-spec(wait_for_refresh(integer(), reference(), Nodes, Nodes) -> Nodes
    when Nodes :: #{inet:ip4_address() => metadata()}).
wait_for_refresh(_StartTime, _Ref, Nodes, Wait) when map_size(Wait) =:= 0 ->
    Nodes;
wait_for_refresh(StartTime, Ref, _Nodes, Wait) ->
    Now = erlang:monotonic_time(millisecond),
    Timeout = force_refresh_timeout() - (Now - StartTime),
    receive
        {lashup_kv_events, #{ref := Ref, value := Value}} ->
            Nodes = dump(Value),
            Wait0 =
                maps:filter(fun (IP, Md) ->
                    Md =:= maps:get(IP, Nodes)
                end, Wait),
            wait_for_refresh(StartTime, Ref, Nodes, Wait0)
    after Timeout ->
        exit(timeout)
    end.

-spec(force_refresh_timeout() -> timeout()).
force_refresh_timeout() ->
    application:get_env(dcos_net, force_refresh_timeout, timer:minutes(5)).

-spec(reachable_nodes() -> [inet:ip4_address()]).
reachable_nodes() ->
    {tree, Tree} = lashup_gm_route:get_tree(node()),
    lists:flatmap(fun (Node) ->
        [_NodeName, IPStr] = string:split(atom_to_list(Node), "@"),
        case inet:parse_ipv4_address(IPStr) of
            {ok, IP} -> [IP];
            {error, _Error} -> []
        end
    end, lashup_gm_route:reachable_nodes(Tree)).

%%%===================================================================
%%% DNS functions
%%%===================================================================

-spec(push_dns_records(inet:ip4_address(), metadata()) -> ok).
push_dns_records(PrivateIP, #{public_ips := PublicIPs}) ->
    ZoneName = <<"thisnode.thisdcos.directory">>,
    Records =
        [ dcos_dns:dns_record(ZoneName, PrivateIP)
        | dcos_dns:dns_records(<<"public.", ZoneName/binary>>, PublicIPs) ],
    _Result = dcos_dns:push_zone(ZoneName, Records),
    ok.
