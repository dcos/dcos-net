%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. May 2016 5:06 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_lashup_vip_listener).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([integer_to_ip/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    lookup_vips/1,
    name_to_ip/2,
    code_change/3]).

-include("dcos_l4lb.hrl").
-include_lib("dns/include/dns.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-type family() :: inet | inet6.
-type ip4_num() :: 0..16#ffffffff.

-record(state, {
    ref = erlang:error() :: reference(),
    min_ip_num = erlang:error(no_min_ip_num) :: ip4_num(),
    max_ip_num = erlang:error(no_max_ip_num) :: ip4_num(),
    last_ip6 = undefined :: inet:ip6_address(),
    vips
    }).
-type state() :: #state{}.

-type key() :: dcos_l4lb_mesos_poller:key().
-type backend() :: dcos_l4lb_mesos_poller:backend().
-type vip2() :: {key(), [backend()]}.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! init,
    {ok, []}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(push_vips, State) ->
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, []) ->
    ets_restart(name_to_ip, bag),
    ets_restart(ip_to_name, set),
    MinIP = ip_to_integer(dcos_l4lb_config:min_named_ip()),
    MaxIP = ip_to_integer(dcos_l4lb_config:max_named_ip()),
    LastIP6 = dcos_l4lb_config:min_named_ip6(),
    {ok, Ref} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({?VIPS_KEY2}) -> true end)),
    {noreply, #state{
        ref = Ref, max_ip_num = MaxIP,
        min_ip_num = MinIP, last_ip6 = LastIP6}};
handle_info({lashup_kv_events, Event = #{ref := Reference}}, State0 = #state{ref = Reference}) ->
    State1 = handle_event(Event, State0),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec(lookup_vips([{ip, inet:ip_address()}|{name, binary()}]) ->
                  [{name, binary()}|{ip, inet:ip_address()}|{badmatch, term()}]).
lookup_vips(Names) ->
    try
        lists:map(fun handle_lookup_vip/1, Names)
    catch
        error:badarg -> []
    end.

handle_lookup_vip({ip, IP}) ->
  case ets:lookup(ip_to_name, IP) of
    [{_, IPName}] -> {name, IPName};
    _ -> {badmatch, IP}
  end;
handle_lookup_vip({name, Name}) when is_binary(Name) ->
  case name_to_ip(inet, Name) of
    [{_, IP}] -> {ip, IP};
    _ -> {badmatch, Name}
  end;
handle_lookup_vip(Arg)  -> {badmatch, Arg}.

handle_event(_Event = #{value := VIPs}, State) ->
    handle_value(VIPs, State).

handle_value(VIPs0, State0) ->
    VIPs1 = process_vips(VIPs0, State0),
    State1 = State0#state{vips = VIPs1},
    ok = push_state_to_dcos_dns(State1),
    dcos_l4lb_mgr:push_vips(VIPs1),
    State1.

process_vips(VIPs0, State) ->
    VIPs1 = lists:map(fun rewrite_keys/1, VIPs0),
    CategorizedVIPs = categories_vips(VIPs1),
    RebindVIPs = [rebind_names(Family, VIPs, State)
                     || {Family, VIPs} <- CategorizedVIPs],
    lists:flatten(RebindVIPs).

rewrite_keys({{RealKey, riak_dt_orswot}, Value}) ->
    {RealKey, Value}.

categories_vips(VIPs) ->
    categories_vips(VIPs, [], []).

categories_vips([], V4_VIPs, V6_VIPs) ->
    [{inet, lists:reverse(V4_VIPs)}, {inet6, lists:reverse(V6_VIPs)}];
categories_vips([VIP|Rest], V4_VIPs, V6_VIPs) ->
    case categories_BE(VIP) of
        [] -> categories_vips(Rest, V4_VIPs, V6_VIPs);
        [inet] -> categories_vips(Rest, [VIP|V4_VIPs], V6_VIPs);
        [inet6] -> categories_vips(Rest, V4_VIPs, [VIP|V6_VIPs]);
        [inet, inet6] -> categories_vips(Rest, [VIP|V4_VIPs], [VIP|V6_VIPs])
    end.

categories_BE({{_Protocol, _Name, _PortNumber}, BEs}) ->
    Families = [dcos_l4lb_app:family(BEIP) || {_IP, {BEIP, _Port}} <- BEs],
    lists:usort(Families).

%% @doc Extracts name based vips. Binds names
-spec(rebind_names(family(), [vip2()], state()) -> [key()]).
rebind_names(_Family, [], _State) ->
    [];
rebind_names(Family, VIPs, State) ->
    Names0 = [Name || {{_Protocol, {name, Name}, _Portnumber}, _Backends} <- VIPs],
    Names1 = lists:map(fun({Name, FWName}) -> binary_to_name([Name, FWName]) end, Names0),
    Names2 = lists:usort(Names1),
    update_name_mapping(Family, Names2, State),
    lists:map(fun(VIP) -> rewrite_name(Family, VIP) end, VIPs).

-spec(rewrite_name(family(), vip2()) -> key()).
rewrite_name(Family, {{Protocol, {name, {Name, FWName}}, PortNum}, BEs}) ->
    FullName = binary_to_name([Name, FWName]),
    [{_, IP}] = name_to_ip(Family, FullName),
    {{Protocol, IP, PortNum}, BEs};
rewrite_name(_, Else) ->
    Else.

push_state_to_dcos_dns(State) ->
    ZoneNames = ?ZONE_NAMES,
    lists:foreach(fun (ZoneName) ->
        Zone = zone(ZoneName, State),
        ok = erldns_zone_cache:put_zone(Zone)
    end, ZoneNames).

-spec(zone([binary()], state()) -> {Name :: binary(), Sha :: binary(), [dns:rr()]}).
zone(ZoneComponents, State) ->
    Now = timeish(),
    zone(Now, ZoneComponents, State).

-spec(timeish() -> 0..4294967295).
timeish() ->
    case erlang:system_time(seconds) of
        Time when Time < 0 ->
            0;
        Time when Time > 4294967295 ->
            4294967295;
        Time ->
            Time + erlang:unique_integer([positive, monotonic])
    end.

-spec(zone(Now :: 0..4294967295, [binary()], state()) -> {Name :: binary(), Sha :: binary(), [dns:rr()]}).
zone(Now, ZoneComponents, _State) ->
    ZoneName = binary_to_name(ZoneComponents),
    Records0 = [
        zone_soa_record(Now, ZoneName, ZoneComponents),
        #dns_rr{
            name = binary_to_name(ZoneComponents),
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = binary_to_name([<<"ns">>|ZoneComponents])
            }
        },
        #dns_rr{
            name = binary_to_name([<<"ns">>|ZoneComponents]),
            type = ?DNS_TYPE_A,
            ttl = 3600,
            data = #dns_rrdata_a{
                ip = {198, 51, 100, 1} %% Default dcos-dns IP
            }
        }
    ],
    {_, Records1} = ets:foldl(fun add_record_fold/2, {ZoneComponents, Records0}, name_to_ip),
    Sha = crypto:hash(sha, term_to_binary(Records1)),
    {ZoneName, Sha, Records1}.

zone_soa_record(Now, ZoneName, ZoneComponents) ->
    #dns_rr{
        name = ZoneName,
        type = ?DNS_TYPE_SOA,
        ttl = 5,
        data = #dns_rrdata_soa{
            mname = binary_to_name([<<"ns">>|ZoneComponents]), %% Nameserver
            rname = <<"support.mesosphere.com">>,
            serial = Now, %% Hopefully there is not more than 1 update/sec :)
            refresh = 5,
            retry = 5,
            expire = 5,
            minimum = 1
        }
    }.

add_record_fold({Name, IP}, {ZoneComponents, Records}) ->
    RecordName = binary_to_name([Name] ++ ZoneComponents),
    Record = case dcos_l4lb_app:family(IP) of
                inet -> #dns_rr{
                          name = RecordName,
                          ttl = 5,
                          type = ?DNS_TYPE_A,
                          data = #dns_rrdata_a{ip = IP}};
                inet6 -> #dns_rr{
                          name = RecordName,
                          ttl = 5,
                          type = ?DNS_TYPE_AAAA,
                          data = #dns_rrdata_aaaa{ip = IP}}
              end,
    {ZoneComponents, [Record|Records]}.

-spec(binary_to_name([binary()]) -> binary()).
binary_to_name(Binaries0) ->
    Binaries1 = lists:map(fun mesos_state:domain_frag/1, Binaries0),
    binary_join(Binaries1, <<".">>).

-spec(binary_join([binary()], Sep :: binary()) -> binary()).
binary_join(Binaries, Sep) ->
    lists:foldr(
        fun
            %% This short-circuits the first run
            (Binary, <<>>) ->
                Binary;
            (<<>>, Acc) ->
                Acc;
            (Binary, Acc) ->
                <<Binary/binary, Sep/binary, Acc/binary>>
        end,
        <<>>,
        Binaries
    ).


-spec(integer_to_ip(IntIP :: 0..4294967295) -> inet:ip4_address()).
integer_to_ip(IntIP) ->
    <<A, B, C, D>> = <<IntIP:32/integer>>,
    {A, B, C, D}.

-spec(ip_to_integer(inet:ip4_address()) -> 0..4294967295).
ip_to_integer(_IP = {A, B, C, D}) ->
    <<IntIP:32/integer>> = <<A, B, C, D>>,
    IntIP.


-spec(update_name_mapping(family(), Names :: term(), State :: state()) -> ok).
update_name_mapping(Family, Names, State) ->
    remove_old_names(Family, Names),
    add_new_names(Family, Names, State),
    ok.

%% This can be rewritten as an enumeration over the ets table, and the names passed to it.
remove_old_names(Family, NewNames) ->
    OldNames = lists:sort([Name || {Name, IP} <- ets:tab2list(name_to_ip),
                                   Family == dcos_l4lb_app:family(IP)]),
    NamesToDelete = ordsets:subtract(OldNames, NewNames),
    lists:foreach(fun(NameToDelete) -> remove_old_name(Family, NameToDelete) end, NamesToDelete).

remove_old_name(Family, NameToDelete) ->
    [ObjToDelete = {_, IP}] = name_to_ip(Family, NameToDelete),
    ets:delete(ip_to_name, IP),
    ets:delete_object(name_to_ip, ObjToDelete).

add_new_names(Family, Names, State) ->
    lists:foreach(fun(Name) -> maybe_add_new_name(Family, Name, State) end, Names).

maybe_add_new_name(Family, Name, State) ->
    case name_to_ip(Family, Name) of
        [] ->
            add_new_name(Family, Name, State);
        _ ->
            ok
    end.

add_new_name(inet, Name, State) ->
    add_new_name_ipv4(Name, State);
add_new_name(inet6, Name, State) ->
    add_new_name_ipv6(Name, State).

add_new_name_ipv4(Name, State = #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) ->
    SearchStart = erlang:phash2(Name, MaxIPNum - MinIPNum),
    add_new_name_ipv4(Name, SearchStart + 1, SearchStart, State).

add_new_name_ipv4(_Name, SearchNext, SearchStart, #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) when
    SearchNext rem (MaxIPNum - MinIPNum) == SearchStart ->
    throw(out_of_ips);
add_new_name_ipv4(Name, SearchNext, SearchStart,
        State = #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) ->
    ActualIPNum = MinIPNum + (SearchNext rem (MaxIPNum - MinIPNum)),
    IP = integer_to_ip(ActualIPNum),
    case ets:lookup(ip_to_name, IP) of
        [] ->
            ets:insert(ip_to_name, {IP, Name}),
            ets:insert(name_to_ip, {Name, IP});
        _ ->
            add_new_name_ipv4(Name, SearchNext + 1, SearchStart, State)
    end.

add_new_name_ipv6(Name, State = #state{last_ip6 = LastIP6}) ->
    MinIP6 = dcos_l4lb_config:min_named_ip6(),
    MaxIP6 = dcos_l4lb_config:max_named_ip6(),
    NextIP6 = next_ip6(LastIP6, MinIP6, MaxIP6),
    case ets:lookup(ip_to_name, NextIP6) of
        [] ->
            ets:insert(ip_to_name, {NextIP6, Name}),
            ets:insert(name_to_ip, {Name, NextIP6});
        _ ->
            add_new_name_ipv6(Name, State#state{last_ip6 = NextIP6})
    end.

next_ip6(IP6, MinIP6, IP6) ->
    MinIP6;
next_ip6({Num0, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0 + 1, 0, 0, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1 + 1, 0, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1, Num2 + 1, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, 16#ffff, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1, Num2, Num3 + 1, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4 + 1, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5 + 1, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, Num6, 16#ffff}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5, Num6 + 1, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7 + 1}.

name_to_ip(Family, Name0) ->
    [{Name1, IP} || {Name1, IP} <- ets:lookup(name_to_ip, Name0),
                    Family == dcos_l4lb_app:family(IP)].

ets_restart(Tab, Type) ->
    catch ets:delete(Tab),
    catch ets:new(Tab, [Type, named_table, protected, {read_concurrency, true}]).

-ifdef(TEST).
state() ->
    %% 9/8
    ets_restart(name_to_ip, bag),
    ets_restart(ip_to_name, set),
    LastIP6 = {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#0},
    #state{ref = undefined, min_ip_num = 16#0b000000, max_ip_num = 16#0b0000fe, last_ip6 = LastIP6}.

check_ip6_test() ->
    MinIP6 = {16#fd01, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 0},
    MaxIP6 = {16#fd01, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff},
    IP6Actual = getIP6(actual, MinIP6, MaxIP6),
    IP6Expected = getIP6(expected, MinIP6, MaxIP6),
    ?assertEqual(IP6Actual, IP6Expected).

getIP6(Flag, MinIP6, MaxIP6) ->
    NextIP6 = test_ip6(Flag, MinIP6, MinIP6, MaxIP6),
    getIP6(Flag, NextIP6, MinIP6, MaxIP6, [NextIP6]).

getIP6(_, _MinIP6, _MinIP6, _, Acc) ->
    Acc;
getIP6(Flag, LastIP6, MinIP6, MaxIP6, Acc) ->
    NextIP6 = test_ip6(Flag, LastIP6, MinIP6, MaxIP6),
    getIP6(Flag, NextIP6, MinIP6, MaxIP6, [NextIP6|Acc]).

test_ip6(actual, LastIP6, MinIP6, MaxIP6) ->
    next_ip6(LastIP6, MinIP6, MaxIP6);
test_ip6(expected, LastIP6, MinIP6, MaxIP6) ->
    test_ip6(LastIP6, MinIP6, MaxIP6).

test_ip6(MaxIP6, MinIP6, MaxIP6) ->
    MinIP6;
test_ip6(IP6, _, _) ->
    {0, NextIP6} = lists:foldr(
        fun (16#ffff, {1, Acc}) -> {1, [0|Acc]};
            (X, {1, Acc}) -> {0, [X+1|Acc]};
            (X, {0, Acc}) -> {0, [X|Acc]}
        end, {1, []}, tuple_to_list(IP6)),
    list_to_tuple(NextIP6).

process_vips_tcp_test() ->
    process_vips(tcp).

process_vips_udp_test() ->
    process_vips(udp).

process_vips(Protocol) ->
    State = state(),
    VIPs = [
        {
            {{Protocol, {1, 2, 3, 4}, 80}, riak_dt_orswot},
            [{{10, 0, 3, 46}, {{10, 0, 3, 46}, 11778}}]
        },
        {
            {{Protocol, {name, {<<"/foo">>, <<"marathon">>}}, 80}, riak_dt_orswot},
            [{{10, 0, 3, 46}, {{10, 0, 3, 46}, 25458}}]
        },
        {
            {{Protocol, {name, {<<"/foo">>, <<"marathon">>}}, 80}, riak_dt_orswot},
            [{{10, 0, 3, 46}, {{16#fe01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, 25678}}]
        }
    ],
    Out = process_vips(VIPs, State),
    Expected = [
        {{Protocol, {1, 2, 3, 4}, 80}, [{{10, 0, 3, 46}, {{10, 0, 3, 46}, 11778}}]},
        {{Protocol, {11, 0, 0, 36}, 80}, [{{10, 0, 3, 46}, {{10, 0, 3, 46}, 25458}}]},
        {{Protocol, {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, 80},
           [{{10, 0, 3, 46}, {{16#fe01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, 25678}}]}
    ],
    ?assertEqual(Expected, Out),
    State.

update_name_mapping_test() ->
    State0 = state(),
    update_name_mapping(inet, [test1, test2, test3], State0),
    NTIList = [{N, I} || {I, N} <- ets:tab2list(ip_to_name)],
    SortedList = lists:reverse(lists:usort(NTIList)),
    ?assertEqual(SortedList, ets:tab2list(name_to_ip)),
    ?assertEqual([{{11, 0, 0, 244}, test1},
                  {{11, 0, 0, 245}, test2},
                  {{11, 0, 0, 246}, test3}],
                  lists:usort(ets:tab2list(ip_to_name))),
    ?assertEqual([{test3, {11, 0, 0, 246}},
                  {test2, {11, 0, 0, 245}},
                  {test1, {11, 0, 0, 244}}],
                  ets:tab2list(name_to_ip)),
    update_name_mapping(inet, [test1, test3], State0),
    ?assertEqual([{{11, 0, 0, 246}, test3}, {{11, 0, 0, 244}, test1}], ets:tab2list(ip_to_name)),
    ?assertEqual([{test3, {11, 0, 0, 246}}, {test1, {11, 0, 0, 244}}], ets:tab2list(name_to_ip)).

update_name_mapping_v6_test() ->
    State0 = state(),
    update_name_mapping(inet6, [test1, test2, test3], State0),
    NTIList = [{N, I} || {I, N} <- ets:tab2list(ip_to_name)],
    SortedList = lists:reverse(lists:usort(NTIList)),
    ?assertEqual(SortedList, ets:tab2list(name_to_ip)),
    ?assertEqual([{{16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, test1},
                  {{16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#2}, test2},
                  {{16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#3}, test3}],
                  lists:usort(ets:tab2list(ip_to_name))),
    ?assertEqual([{test3, {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#3}},
                  {test2, {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#2}},
                  {test1, {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}}],
                  ets:tab2list(name_to_ip)),
    update_name_mapping(inet6, [test1, test3], State0),
    ?assertEqual([{{16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, test1},
                  {{16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#3}, test3}],
                  ets:tab2list(ip_to_name)),
    ?assertEqual([{test3, {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#3}},
                  {test1, {16#fd01, 16#c, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}}],
                  ets:tab2list(name_to_ip)).


zone_test() ->
    State = process_vips(tcp),
    Components = [<<"l4lb">>, <<"thisdcos">>, <<"directory">>],
    Zone = zone(1463878088, Components, State),
    Expected =
        {<<"l4lb.thisdcos.directory">>,
           <<158, 253, 241, 209, 102, 111, 218, 254, 243, 141,
             13, 251, 128, 184, 172, 162, 58, 251, 130, 236>>,
           [
             {dns_rr, <<"foo.marathon.l4lb.thisdcos.directory">>, 1, 28, 5,
               {dns_rrdata_aaaa, {64769 , 12, 0, 0, 0, 0, 0, 1}}},
             {dns_rr, <<"foo.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
               {dns_rrdata_a, {11, 0, 0, 36}}},
             {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 6, 5,
               {dns_rrdata_soa, <<"ns.l4lb.thisdcos.directory">>,
                  <<"support.mesosphere.com">>, 1463878088, 5, 5, 5, 1}},
             {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 2, 3600,
               {dns_rrdata_ns, <<"ns.l4lb.thisdcos.directory">>}},
             {dns_rr, <<"ns.l4lb.thisdcos.directory">>, 1, 1, 3600,
               {dns_rrdata_a, {198, 51, 100, 1}}}
           ]
        },

    ?assertEqual(Expected, Zone).
%%
%%    Expected = {<<"l4lb.thisdcos.directory">>,
%%        <<161, 204, 13, 14, 64, 13, 80, 62, 140, 205, 206, 161, 238, 57, 215,
%%            246, 172, 97, 183, 176>>,
%%        [{dns_rr, <<"foo4.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%            {dns_rrdata_a, {11, 0, 0, 86}}},
%%            {dns_rr, <<"foo3.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 0}}},
%%            {dns_rr, <<"foo2.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 108}}},
%%            {dns_rr, <<"foo1.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 36}}},
%%            {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 6, 5,
%%                {dns_rrdata_soa, <<"ns.l4lb.thisdcos.directory">>,
%%                    <<"support.mesosphere.com">>, 1463878088, 5, 5, 5, 1}},
%%            {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 2, 3600,
%%                {dns_rrdata_ns, <<"ns.l4lb.thisdcos.directory">>}},
%%            {dns_rr, <<"ns.l4lb.thisdcos.directory">>, 1, 1, 3600,
%%                {dns_rrdata_a, {198, 51, 100, 1}}}]},
%%    ?assertEqual(Expected, Zone).
%%
overallocate_test() ->
    State = #state{max_ip_num = Max, min_ip_num = Min} = state(),
    FakeNames = lists:seq(1, Max - Min + 1),
    ?assertThrow(out_of_ips, update_name_mapping(inet, FakeNames, State)).


ip_to_integer_test() ->
    ?assertEqual(4278190080, ip_to_integer({255, 0, 0, 0})),
    ?assertEqual(0, ip_to_integer({0, 0, 0, 0})),
    ?assertEqual(16711680, ip_to_integer({0, 255, 0, 0})),
    ?assertEqual(65535, ip_to_integer({0, 0, 255, 255})),
    ?assertEqual(16909060, ip_to_integer({1, 2, 3, 4})).

integer_to_ip_test() ->
    ?assertEqual({255, 0, 0, 0}, integer_to_ip(4278190080)),
    ?assertEqual({0, 0, 0, 0}, integer_to_ip(0)),
    ?assertEqual({0, 255, 0, 0}, integer_to_ip(16711680)),
    ?assertEqual({0, 0, 255, 255}, integer_to_ip(65535)),
    ?assertEqual({1, 2, 3, 4}, integer_to_ip(16909060)).


all_prop_test_() ->
    {timeout, 60, [fun() -> [] = proper:module(?MODULE, [{to_file, user}, {numtests, 100}]) end]}.


ip() ->
    {byte(), byte(), byte(), byte()}.
int_ip() ->
    integer(0, 4294967295).

valid_int_ip_range(Int) when Int >= 0 andalso Int =< 4294967295 ->
    true;
valid_int_ip_range(_) ->
    false.

prop_integer_to_ip() ->
    ?FORALL(
        IP,
        ip(),
        valid_int_ip_range(ip_to_integer(IP))
    ).

prop_integer_and_back() ->
    ?FORALL(
        IP,
        ip(),
        integer_to_ip(ip_to_integer(IP)) =:= IP
    ).

prop_ip_and_back() ->
    ?FORALL(
        IntIP,
        int_ip(),
        ip_to_integer(integer_to_ip(IntIP)) =:= IntIP
    ).

-endif.
