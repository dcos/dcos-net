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
-define(MAIN_TABLE, 254). %% main table
-define(MINUTEMAN_IFACE, "minuteman").
-define(LO_IFACE, "lo").

-record(state, {
    netns :: map()
}).

-record(params, {
    pid :: pid(),
    iface :: non_neg_integer(),
    lo_iface :: non_neg_integer() | undefined
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
    {ok, LoIface} = gen_netlink_client:if_nametoindex(?LO_IFACE),
    Params = #params{pid = Pid, iface = Iface, lo_iface = LoIface},
    {ok, #state{netns = #{host => Params}}}.

handle_call({get_routes, Namespace}, _From, State) ->
    Routes = handle_get_routes(Namespace, State),
    {reply, Routes, State};
handle_call({add_routes, Routes, Namespace}, _From, State) ->
    update_routes(Routes, newroute, Namespace, State),
    {reply, ok, State};
handle_call({remove_routes, Routes, Namespace}, _From, State) ->
    update_routes(Routes, delroute, Namespace, State),
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
    V4_Routes = handle_get_route2(inet, ?LOCAL_TABLE, maps:get(Namespace, NetnsMap)),
    %% For v6, we add routes both in local and main table. However, the routes
    %% in local table are on loopback interface. Hence, we do a route lookup on main
    %% table to filter them based on minuteman interface
    V6_Routes = handle_get_route2(inet6, ?MAIN_TABLE, maps:get(Namespace, NetnsMap)),
    ordsets:union(V4_Routes, V6_Routes).

handle_get_route2(Family, Table, #params{pid = Pid, iface = Iface}) ->
    Req = [{table, Table}, {oif, Iface}],
    {ok, Raw} = gen_netlink_client:rtnl_request(Pid, getroute, [match, root],
                                                {Family, 0, 0, 0, 0, 0, 0, 0, [], Req}),
    Routes = [route_msg_dst(Msg) || #rtnetlink{msg = Msg} <- Raw,
                                    dcos_l4lb_app:prefix_len(Family) == element(2, Msg),
                                    Iface == route_msg_oif(Msg),
                                    Table == route_msg_table(Msg)],
    lager:info("Get routes ~p ~p", [Iface, Routes]),
    ordsets:from_list(Routes).

%% see netlink.hrl for the element position
route_msg_oif(Msg) -> proplists:get_value(oif, element(10, Msg)).
route_msg_dst(Msg) -> proplists:get_value(dst, element(10, Msg)).
route_msg_table(Msg) -> proplists:get_value(table, element(10, Msg)).

update_routes(Routes, Action, Namespace, #state{netns = NetnsMap}) ->
    lager:info("~p ~p ~p", [Action, Namespace, Routes]),
    Params = maps:get(Namespace, NetnsMap),
    lists:foreach(fun(Route) ->
                    perform_action(Route, Action, Namespace, Params)
                  end, Routes).

perform_action(Dst, Action, Namespace, Params = #params{pid = Pid}) ->
    Flags = rt_flags(Action),
    Routes = make_routes(Dst, Namespace, Params), %% v6 has two routes
    lists:foreach(fun(Route) ->
                    perform_action2(Pid, Action, Flags, Route)
                  end, Routes).

perform_action2(Pid, Action, Flags, Route) ->
    Result = gen_netlink_client:rtnl_request(Pid, Action, Flags, Route),
    case {Action, Result} of
      {_, {ok, _}} -> ok;
      {delroute, {_, 16#FD, []}} -> ok; %% route doesn't exists
      {_, {_, Error, []}} ->
         lager:error("Encountered error while ~p ~p ~p", [Action, Route, Error])
    end.

make_routes(Dst, Namespace, #params{iface = Iface, lo_iface = LoIface}) ->
    Family = dcos_l4lb_app:family(Dst),
    Attr = {Dst, Family, Namespace},
    case Family of
      inet -> [make_route(Attr, Iface, ?LOCAL_TABLE)];
      inet6 ->  [make_route(Attr, LoIface, ?LOCAL_TABLE), %% order is important
                 make_route(Attr, Iface, ?MAIN_TABLE)]
    end.

make_route({Dst, Family, Namespace}, Iface, Table) ->
    PrefixLen = dcos_l4lb_app:prefix_len(Family),
    Msg = [{table, Table}, {dst, Dst}, {oif, Iface}],
    {
        Family,
        _PrefixLen = PrefixLen,
        _SrcPrefixLen = 0,
        _Tos = 0,
        _Table = Table,
        _Protocol = boot,
        _Scope = rt_scope(Namespace),
        _Type = rt_type(Namespace, Table),
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

rt_type(host, ?LOCAL_TABLE) -> local;
rt_type(_, _) -> unicast.

rt_flags(newroute) -> [create, replace];
rt_flags(delroute) -> [].
