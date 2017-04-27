%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Nov 2016 9:36 AM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_route_mgr).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0, 
         update_routes/2,
         push_routes/2,
         update_netns/3]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-ifdef(TEST).
-export([get_routes/2]).
-endif.

-define(SERVER, ?MODULE).
-define(IFIDX_LO, 1).

-record(state, {
    netlink :: pid(),
    netns_netlink = #{} :: map(),
    routes :: ordsets:ordset(),
    iface :: non_neg_integer()
}).

-type state() :: state().
-include_lib("gen_netlink/include/netlink.hrl").
-include("dcos_l4lb.hrl").
-define(LOCAL_TABLE, 255). %% local table
-define(MINUTEMAN_IFACE, "minuteman").


%%%===================================================================
%%% API
%%%===================================================================

update_routes(Pid, Routes) ->
    gen_server:call(Pid, {update_routes, Routes}).

push_routes(Pid, Namespaces) ->
    gen_server:call(Pid, {push_routes, Namespaces}).

update_netns(Pid, UpdateType, UpdateValue) ->
    gen_server:call(Pid, {update_netns, {UpdateType, UpdateValue}}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    {ok, Iface} = gen_netlink_client:if_nametoindex(?MINUTEMAN_IFACE),
    Routes = get_routes(Pid, Iface),
    {ok, #state{netlink = Pid, routes = Routes, iface = Iface}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: state()) ->
    {reply, Reply :: term(), NewState :: state()} |
    {reply, Reply :: term(), NewState :: state(), timeout() | hibernate} |
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: state()} |
    {stop, Reason :: term(), NewState :: state()}).
handle_call({update_routes, Routes}, _From, State0) ->
    State1 = handle_update_routes(Routes, State0),
    {reply, ok, State1};
handle_call({push_routes, Namespaces}, _From, State) ->
    handle_push_routes(Namespaces, State),
    {reply, ok, State};
handle_call({update_netns, {UpdateType, UpdateValue}}, _From, State0) ->
    {Reply, State1} = handle_update_netns(UpdateType, UpdateValue, State0),
    {reply, Reply, State1};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: state()}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: state()}).
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: state()) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: state(),
    Extra :: term()) ->
    {ok, NewState :: state()} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
get_routes(Pid, Iface) ->
    Req = [{table, ?LOCAL_TABLE}, {oif, Iface}],
    {ok, Raw} = gen_netlink_client:rtnl_request(Pid, getroute, [match, root],
                                                {inet, 0, 0, 0, 0, 0, 0, 0, [], Req}),
    Routes0 = [route_msg_dst(Msg) || #rtnetlink{msg = Msg} <- Raw,
                                     Iface == route_msg_oif(Msg)],
    ordsets:from_list(Routes0).

%% see netlink.hrl for the element position
route_msg_oif(Msg) -> proplists:get_value(oif, element(10, Msg)).
route_msg_dst(Msg) -> proplists:get_value(dst, element(10, Msg)).

handle_update_routes(NewRoutes, State0 = #state{routes = OldRoutes}) ->
    RoutesToDelete = ordsets:subtract(OldRoutes, NewRoutes),
    RoutesToAdd = ordsets:subtract(NewRoutes, OldRoutes),
    lists:foreach(fun(Route) -> add_route(Route, State0) end, RoutesToAdd),
    lists:foreach(fun(Route) -> remove_route(Route, State0) end, RoutesToDelete),
    State0#state{routes = NewRoutes}.

handle_push_routes(Namespaces, State = #state{routes = Routes}) ->
    lists:foreach(fun(Namespace) -> add_routes(Namespace, Routes, State) end, Namespaces).

add_routes(Namespace, Routes, #state{netns_netlink = NetnsMap}) ->
    Pid = maps:get(Namespace, NetnsMap),
    lists:foreach(fun(Route) -> add_route(Route, Pid) end, Routes). 

add_route(Dst, #state{netlink = Pid, iface = Iface}) ->
    Msg = [{table, ?LOCAL_TABLE}, {dst, Dst}, {oif, Iface}],
    add_route2(Pid, Msg);
add_route(Dst, Pid) ->
    Msg = [{table, ?LOCAL_TABLE}, {dst, Dst}, {oif, ?IFIDX_LO}],
    add_route2(Pid, Msg).

add_route2(Pid, Msg) ->
    Route = {
        inet,
        _PrefixLen = 32,
        _SrcPrefixLen = 0,
        _Tos = 0,
        _Table = ?LOCAL_TABLE,
        _Protocol = boot,
        _Scope = host,
        _Type = local,
        _Flags = [],
        Msg},
    {ok, _} = gen_netlink_client:rtnl_request(Pid, newroute, [create, replace], Route).

remove_route(Dst, #state{netlink = Pid, iface = Iface}) ->
    Msg = [{table, ?LOCAL_TABLE}, {dst, Dst}, {oif, Iface}],
    Route = {
        inet,
        _PrefixLen = 32,
        _SrcPrefixLen = 0,
        _Tos = 0,
        _Table = ?LOCAL_TABLE,
        _Protocol = boot,
        _Scope = host,
        _Type = local,
        _Flags = [],
        Msg},
    {ok, _} = gen_netlink_client:rtnl_request(Pid, delroute, [], Route).

handle_update_netns(add_netns, Netnslist, State = #state{netns_netlink = NetnsMap0}) ->
    NetnsMap1 = lists:foldl(fun maybe_add_netns/2, maps:new(), Netnslist),
    NetnsMap2 = maps:merge(NetnsMap1, NetnsMap0),
    {maps:keys(NetnsMap1), State#state{netns_netlink = NetnsMap2}};
handle_update_netns(remove_netns, Netnslist, State = #state{netns_netlink = NetnsMap0}) ->
    NetnsMap1 = lists:foldl(fun maybe_remove_netns/2, NetnsMap0, Netnslist),
    RemovedNs = lists:subtract(maps:keys(NetnsMap0), maps:keys(NetnsMap1)),
    {RemovedNs, State#state{netns_netlink = NetnsMap1}};
handle_update_netns(reconcile_netns, Netnslist, State0 = #state{netns_netlink = NetnsMap0}) ->
    AddNetns = [Netns || Netns = #netns{id = Id} <- Netnslist, not maps:is_key(Id, NetnsMap0)],
    RemoveNetns = [#netns{id = Id} || Id <- maps:keys(NetnsMap0), not lists:keymember(Id, 2, Netnslist)],
    {_, State1} = handle_update_netns(remove_netns, RemoveNetns, State0),
    handle_update_netns(add_netns, AddNetns, State1).
   
maybe_add_netns(Netns = #netns{id = Id}, NetnsMap) ->
    maybe_add_netns(maps:is_key(Id, NetnsMap), Netns, NetnsMap).

maybe_add_netns(true, _, NetnsMap) ->
    NetnsMap;
maybe_add_netns(false, #netns{id = Id, ns = Namespace}, NetnsMap) ->
    case gen_netlink_client:start_link(netns, ?NETLINK_ROUTE, binary_to_list(Namespace)) of
        {ok, Pid} ->
            maps:put(Id, Pid, NetnsMap);
        {error, Reason} ->
            lager:error("Couldn't create route netlink client for ~p due to ~p", [Id, Reason]),
            NetnsMap
    end.

maybe_remove_netns(Netns = #netns{id = Id}, NetnsMap) ->
    maybe_remove_netns(maps:is_key(Id, NetnsMap), Netns, NetnsMap).

maybe_remove_netns(true, #netns{id = Id}, NetnsMap) ->
    Pid = maps:get(Id, NetnsMap),
    erlang:unlink(Pid),
    gen_netlink_client:stop(Pid),
    maps:remove(Id, NetnsMap);
maybe_remove_netns(false, _, NetnsMap) ->
    NetnsMap.
