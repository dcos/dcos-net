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
         get_routes/2,
         add_routes/3,
         remove_routes/3,
         add_netns/2,
         remove_netns/2]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).


-include_lib("gen_netlink/include/netlink.hrl").
-include("dcos_l4lb.hrl").

-define(LOCAL_TABLE, 255). %% local table
-define(MINUTEMAN_IFACE, "minuteman").

-record(state, {
    netns :: map()
}).

-record(params, {
    pid :: pid(),
    iface :: non_neg_integer()
}).

%%%===================================================================
%%% API
%%%===================================================================
get_routes(Pid, Namespace) ->
    gen_server:call(Pid, {get_routes, Namespace}).

add_routes(Pid, Routes, Namespace) ->
    gen_server:call(Pid, {add_routes, Routes, Namespace}).

remove_routes(Pid, Routes, Namespace) ->
    gen_server:call(Pid, {remove_routes, Routes, Namespace}).

add_netns(Pid, UpdateValue) ->
    gen_server:call(Pid, {add_netns, UpdateValue}).

remove_netns(Pid, UpdateValue) ->
    gen_server:call(Pid, {remove_netns, UpdateValue}).

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

init([]) ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    {ok, Iface} = gen_netlink_client:if_nametoindex(?MINUTEMAN_IFACE),
    Params = #params{pid = Pid, iface = Iface},
    {ok, #state{netns = #{host => Params}}}.

handle_call({get_routes, Namespace}, _From, State) ->
    Routes = handle_get_routes(Namespace, State),
    {reply, Routes, State};
handle_call({add_routes, Routes, Namespace}, _From, State) ->
    handle_add_routes(Routes, Namespace, State),
    {reply, ok, State};
handle_call({remove_routes, Routes, Namespace}, _From, State) ->
    handle_remove_routes(Routes, Namespace, State),
    {reply, ok, State};
handle_call({add_netns, UpdateValue}, _From, State0) ->
    {Reply, State1} = handle_add_netns(UpdateValue, State0),
    {reply, Reply, State1};
handle_call({remove_netns, UpdateValue}, _From, State0) ->
    {Reply, State1} = handle_remove_netns(UpdateValue, State0),
    {reply, Reply, State1};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_get_routes(Namespace, #state{netns = NetnsMap}) ->
    handle_get_route2(maps:get(Namespace, NetnsMap)).

handle_get_route2(#params{pid = Pid, iface = Iface}) ->
    Req = [{table, ?LOCAL_TABLE}, {oif, Iface}],
    {ok, Raw} = gen_netlink_client:rtnl_request(Pid, getroute, [match, root],
                                                {inet, 0, 0, 0, 0, 0, 0, 0, [], Req}),
    Routes = [route_msg_dst(Msg) || #rtnetlink{msg = Msg} <- Raw,
                                     Iface == route_msg_oif(Msg)],
    lager:info("Get routes ~p ~p ~p", [Iface, Routes]),
    ordsets:from_list(Routes).

%% see netlink.hrl for the element position
route_msg_oif(Msg) -> proplists:get_value(oif, element(10, Msg)).
route_msg_dst(Msg) -> proplists:get_value(dst, element(10, Msg)).

handle_add_routes(RoutesToAdd, Namespace, State) ->
    lager:info("Adding routes to Namespace ~p ~p", [Namespace, RoutesToAdd]),
    lists:foreach(fun(Route) -> add_route(Route, Namespace, State) end, RoutesToAdd).

handle_remove_routes(RoutesToDelete, Namespace, State) ->
    lager:info("Removing routes from Namespace ~p ~p", [Namespace, RoutesToDelete]),
    lists:foreach(fun(Route) -> remove_route(Route, Namespace, State) end, RoutesToDelete).

add_route(Dst, Namespace, #state{netns = NetnsMap}) ->
    add_route2(Dst, Namespace, maps:get(Namespace, NetnsMap)).

add_route2(Dst, Namespace, Params = #params{pid = Pid}) ->
    Route = get_route2(Dst, Namespace, Params),
    {ok, _} = gen_netlink_client:rtnl_request(Pid, newroute, [create, replace], Route).

remove_route(Dst, Namespace, #state{netns = NetnsMap}) ->
    remove_route2(Dst, Namespace, maps:get(Namespace, NetnsMap)).

remove_route2(Dst, Namespace, Params = #params{pid = Pid}) ->
    Route = get_route2(Dst, Namespace, Params),
    {ok, _} = gen_netlink_client:rtnl_request(Pid, delroute, [], Route).

get_route2(Dst, Namespace, #params{iface = Iface}) ->
    Msg = [{table, ?LOCAL_TABLE}, {dst, Dst}, {oif, Iface}],
    {
        inet,
        _PrefixLen = 32,
        _SrcPrefixLen = 0,
        _Tos = 0,
        _Table = ?LOCAL_TABLE,
        _Protocol = boot,
        _Scope = rt_scope(Namespace),
        _Type = rt_type(Namespace),
        _Flags = [],
        Msg
    }.

handle_add_netns(Netnslist, State = #state{netns = NetnsMap0}) ->
    NetnsMap1 = lists:foldl(fun maybe_add_netns/2, maps:new(), Netnslist),
    NetnsMap2 = maps:merge(NetnsMap1, NetnsMap0),
    {maps:keys(NetnsMap1), State#state{netns = NetnsMap2}}.

handle_remove_netns(Netnslist, State = #state{netns = NetnsMap0}) ->
    NetnsMap1 = lists:foldl(fun maybe_remove_netns/2, NetnsMap0, Netnslist),
    RemovedNs = lists:subtract(maps:keys(NetnsMap0), maps:keys(NetnsMap1)),
    {RemovedNs, State#state{netns = NetnsMap1}}.

maybe_add_netns(Netns = #netns{id = Id}, NetnsMap) ->
    maybe_add_netns(maps:is_key(Id, NetnsMap), Netns, NetnsMap).

maybe_add_netns(true, _, NetnsMap) ->
    NetnsMap;
maybe_add_netns(false, #netns{id = Id, ns = Namespace}, NetnsMap) ->
    NsStr = binary_to_list(Namespace),
    case gen_netlink_client:start_link(netns, ?NETLINK_ROUTE, NsStr) of
        {ok, Pid} ->
            {ok, Iface} = gen_netlink_client:if_nametoindex(?MINUTEMAN_IFACE, NsStr),
            Params = #params{pid = Pid, iface = Iface},
            maps:put(Id, Params, NetnsMap);
        {error, Reason} ->
            lager:error("Couldn't create route netlink client for ~p due to ~p", [Id, Reason]),
            NetnsMap
    end.

maybe_remove_netns(Netns = #netns{id = Id}, NetnsMap) ->
    maybe_remove_netns(maps:is_key(Id, NetnsMap), Netns, NetnsMap).

maybe_remove_netns(true, #netns{id = Id}, NetnsMap) ->
    #params{pid = Pid} = maps:get(Id, NetnsMap),
    erlang:unlink(Pid),
    gen_netlink_client:stop(Pid),
    maps:remove(Id, NetnsMap);
maybe_remove_netns(false, _, NetnsMap) ->
    NetnsMap.

rt_scope(host) -> host;
rt_scope(_) -> link.

rt_type(host) -> local;
rt_type(_) -> unicast.
