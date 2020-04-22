-module(dcos_l4lb_lashup_vip_listener).
-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    start_link/0,
    ip2name/1,
    to_name/1
]).

%% gen_server callbacks
-export([init/1, handle_continue/2,
    handle_call/3, handle_cast/2, handle_info/2]).

-include("dcos_l4lb.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-record(state, {
    ref = erlang:error() :: reference(),
    gc_ref :: undefined | reference()
}).
-type state() :: #state{}.

-type family() :: inet | inet6.
-type lkey() :: dcos_l4lb_mesos_poller:lkey().
-type key() :: dcos_l4lb_mesos_poller:key().
-type backend() :: dcos_l4lb_mesos_poller:backend().

-define(NAME2IP, dcos_l4lb_name_to_ip).
-define(IP2NAME, dcos_l4lb_ip_to_name).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec(ip2name(inet:ip_address()) -> false | binary()).
ip2name(IP) ->
    try ets:lookup(?IP2NAME, IP) of
        [{IP, {_Family, FwName, Label}}] ->
            to_name([Label, FwName]);
        [] -> false
    catch error:badarg ->
        false
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    EtsOpts = [named_table, protected, {read_concurrency, true}],
    ets:new(?NAME2IP, EtsOpts),
    ets:new(?IP2NAME, EtsOpts),
    {ok, {}, {continue, {}}}.

handle_continue({}, {}) ->
    MatchSpec = ets:fun2ms(fun ({?VIPS_KEY2}) -> true end),
    {ok, Ref} = lashup_kv:subscribe(MatchSpec),
    {noreply, #state{ref = Ref}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({lashup_kv_event, Ref, Key}, #state{ref=Ref}=State) ->
    ok = lashup_kv:flush(Ref, Key),
    Value = lashup_kv:value(Key),
    ok = handle_event(Value),
    {noreply, start_gc_timer(State)};
handle_info({timeout, GCRef, gc}, #state{gc_ref=GCRef}=State) ->
    {noreply, State#state{gc_ref=undefined}, hibernate};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_gc_timer(state()) -> state()).
start_gc_timer(#state{gc_ref = undefined} = State) ->
    Timeout = application:get_env(dcos_net, gc_timeout, 15000),
    TRef = erlang:start_timer(Timeout, self(), gc),
    State#state{gc_ref = TRef};
start_gc_timer(State) ->
    State.

-spec(handle_event([{lkey(), [backend()]}]) -> ok).
handle_event(RawVIPs) ->
    VIPs = process_vips(RawVIPs),
    ok = cleanup_mappings(VIPs),
    ok = dcos_l4lb_mgr:push_vips(VIPs),
    ok = push_dns_zone().

-spec(process_vips([{lkey(), [backend()]}]) -> [{key(), [backend()]}]).
process_vips(VIPs) ->
    lists:flatmap(fun process_vip/1, VIPs).

-spec(process_vip({lkey(), [backend()]}) -> [{key(), [backend()]}]).
process_vip({{Key, riak_dt_orswot}, Value}) ->
    process_vip(Key, Value).

-spec(process_vip(key(), [backend()]) -> [{key(), [backend()]}]).
process_vip({Protocol, {name, {Label, FwName}}, Port}, AllBEs) ->
    CategorizedBEs = categorize_backends(AllBEs),
    lists:map(fun ({Family, BEs}) ->
        IP = maybe_add_mapping(Family, FwName, Label),
        {{Protocol, IP, Port}, BEs}
    end, CategorizedBEs);
process_vip(_Key, []) ->
    [];
process_vip(Key, BEs) ->
    [{Key, BEs}].

-spec(categorize_backends([backend()]) -> [{family(), [backend()]}]).
categorize_backends(BEs) ->
    lists:foldl(fun (BE, Acc) ->
        case BE of
            {_AgentIP, {IP, _Port, _Weight}} ->
                BE0 = BE;
            {AgentIP, {IP, Port}} ->
                BE0 = {AgentIP, {IP, Port, 1}}
        end,
        Family = dcos_l4lb_app:family(IP),
        orddict:append(Family, BE0, Acc)
    end, orddict:new(), BEs).

-ifdef(TEST).

-define(BE4, {{2, 3, 4, 5}, {{1, 2, 3, 4}, 80, 1}}).
-define(BE4OLD, {{3, 4, 5, 6}, {{1, 2, 3, 5}, 80}}).
-define(BE6, {{2, 3, 4, 5}, {{1, 0, 0, 0, 0, 0, 0, 1}, 80, 1}}).
-define(BE6OLD, {{3, 4, 5, 6}, {{1, 0, 0, 0, 0, 0, 0, 2}, 80}}).

categorize_backends_test() ->
    ?assertEqual(
       [{inet, [{{2, 3, 4, 5}, {{1, 2, 3, 4}, 80, 1}},
                {{3, 4, 5, 6}, {{1, 2, 3, 5}, 80, 1}}]},
        {inet6, [{{2, 3, 4, 5}, {{1, 0, 0, 0, 0, 0, 0, 1}, 80, 1}},
                 {{3, 4, 5, 6}, {{1, 0, 0, 0, 0, 0, 0, 2}, 80, 1}}]}],
       categorize_backends([?BE4, ?BE4OLD, ?BE6, ?BE6OLD])).

-endif.

%%%===================================================================
%%% Mapping functions
%%%===================================================================

-spec(maybe_add_mapping(family(), binary(), binary()) -> inet:ip_address()).
maybe_add_mapping(Family, FwName, Label) ->
    case ets:lookup(?NAME2IP, {Family, FwName, Label}) of
        [{_Key, IP}] -> IP;
        [] ->
            IP = add_mapping(Family, FwName, Label),
            ?LOG_NOTICE("VIP mapping was added: ~p -> ~p",
                        [{Label, FwName}, IP]),
            IP
    end.

-spec(add_mapping(family(), binary(), binary()) -> inet:ip_address()).
add_mapping(Family, FwName, Label) ->
    MinMaxIP = minmax_ip(Family),
    % Get hashed-based ip address.
    Name = to_name([Label, FwName]),
    {Qtty, InitIP} = init_ip(Family, Name, MinMaxIP),
    % Get the next avaliable ip address if threre is a hash collision.
    add_mapping(Family, FwName, Label, MinMaxIP, InitIP, Qtty).

-spec(add_mapping(family(), binary(), binary(), {IP, IP}, IP, Qtty) -> IP
    when IP :: inet:ip_address(), Qtty :: non_neg_integer()).
add_mapping(Family, FwName, Label, MinMaxIP, _IP, 0) ->
    throw({out_of_ips, Family, FwName, Label, MinMaxIP});
add_mapping(Family, FwName, Label, MinMaxIP, IP, Qtty) ->
    case ets:insert_new(?IP2NAME, {IP, {Family, FwName, Label}}) of
        true ->
            ets:insert(?NAME2IP, {{Family, FwName, Label}, IP}),
            IP;
        false ->
            NextIP = next_ip(Family, MinMaxIP, IP),
            add_mapping(Family, FwName, Label, MinMaxIP, NextIP, Qtty - 1)
    end.

-spec(cleanup_mappings([{key(), [backend()]}]) -> ok).
cleanup_mappings(VIPs) ->
    AllIPs = ets:select(?IP2NAME, [{{'$1', '_'}, [], ['$1']}]),
    NewIPs = maps:from_list([{IP, true} || {{_, IP, _}, _} <- VIPs]),
    OldIPs = [IP || IP <- AllIPs, not maps:is_key(IP, NewIPs)],
    lists:foreach(fun (IP) ->
        [{IP, {_Family, FwName, Label}=Key}] = ets:take(?IP2NAME, IP),
        ets:delete(?NAME2IP, Key),
        ?LOG_NOTICE("VIP mapping was removed: ~p -> ~p",
                   [{Label, FwName}, IP])
    end, OldIPs).

%%%===================================================================
%%% Next IP functions
%%%===================================================================

-spec(minmax_ip(family()) -> {IP, IP}
    when IP :: inet:ip_address()).
minmax_ip(inet) ->
    {dcos_l4lb_config:min_named_ip(),
     dcos_l4lb_config:max_named_ip()};
minmax_ip(inet6) ->
    {dcos_l4lb_config:min_named_ip6(),
     dcos_l4lb_config:max_named_ip6()}.

-spec(next_ip(family(), {IP, IP}, IP) -> IP
    when IP :: inet:ip_address()).
next_ip(inet, {MinIP, MaxIP}, IP) ->
    next_ip4(IP, MinIP, MaxIP);
next_ip(inet6, {MinIP, MaxIP}, IP) ->
    next_ip6(IP, MinIP, MaxIP).

-spec(next_ip4(IP, IP, IP) -> IP
    when IP :: inet:ip4_address()).
next_ip4(IP4, MinIP4, IP4) ->
    MinIP4;
next_ip4({A, 16#ff, 16#ff, 16#ff}, _, _) ->
    {A + 1, 0, 0, 0};
next_ip4({A, B, 16#ff, 16#ff}, _, _) ->
    {A, B + 1, 0, 0};
next_ip4({A, B, C, 16#ff}, _, _) ->
    {A, B, C + 1, 0};
next_ip4({A, B, C, D}, _, _) ->
    {A, B, C, D + 1}.

-define(FFFF, 16#ffff).
-spec(next_ip6(IP, IP, IP) -> IP
    when IP :: inet:ip6_address()).
next_ip6(IP6, MinIP6, IP6) ->
    MinIP6;
next_ip6({Num0, ?FFFF, ?FFFF, ?FFFF, ?FFFF, ?FFFF, ?FFFF, ?FFFF}, _, _) ->
    {Num0 + 1, 0, 0, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, ?FFFF, ?FFFF, ?FFFF, ?FFFF, ?FFFF, ?FFFF}, _, _) ->
    {Num0, Num1 + 1, 0, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, ?FFFF, ?FFFF, ?FFFF, ?FFFF, ?FFFF}, _, _) ->
    {Num0, Num1, Num2 + 1, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, ?FFFF, ?FFFF, ?FFFF, ?FFFF}, _, _) ->
    {Num0, Num1, Num2, Num3 + 1, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, ?FFFF, ?FFFF, ?FFFF}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4 + 1, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, ?FFFF, ?FFFF}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5 + 1, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, Num6, ?FFFF}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5, Num6 + 1, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7 + 1}.

-spec(init_ip(family(), binary(), {inet:ip_address(), inet:ip_address()}) ->
    {Qtty :: pos_integer(), inet:ip_address()}).
init_ip(Family, Name, {MinIP, MaxIP}) ->
    MinIPn = ip2int(Family, MinIP),
    MaxIPn = ip2int(Family, MaxIP),
    Qtty = MaxIPn - MinIPn,
    InitIPn = MinIPn + hash(Family, Name, Qtty),
    {Qtty, int2ip(Family, InitIPn)}.

-spec(hash(family(), binary(), Qtty :: pos_integer()) -> non_neg_integer()).
hash(inet, Name, Qtty) ->
    erlang:phash2(Name, Qtty);
hash(inet6, Name, Qtty) ->
    <<Hash:160>> = crypto:hash(sha, Name),
    Hash rem Qtty.

-spec(ip2int(family(), inet:ip_address()) -> non_neg_integer()).
ip2int(inet, {A, B, C, D}) ->
    <<IntIP:32/integer>> = <<A, B, C, D>>,
    IntIP;
ip2int(inet6, {A, B, C, D, E, F, G, H}) ->
    <<IntIP:128/integer>> = <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>,
    IntIP.

-spec(int2ip(family(), non_neg_integer()) -> inet:ip_address()).
int2ip(inet, IntIP) ->
    <<A, B, C, D>> = <<IntIP:32/integer>>,
    {A, B, C, D};
int2ip(inet6, IntIP) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>> = <<IntIP:128/integer>>,
    {A, B, C, D, E, F, G, H}.

%%%===================================================================
%%% DNS functions
%%%===================================================================

-spec(push_dns_zone() -> ok).
push_dns_zone() ->
    ZoneName = to_name(?L4LB_ZONE_NAME),
    Records = records(?L4LB_ZONE_NAME),
    ok = dcos_dns:push_zone(ZoneName, Records).

-spec(records([binary()]) -> [dns:rr()]).
records(ZoneComponents) ->
    ets:foldl(
        fun ({Key, Value}, Acc) ->
            Record = to_record(ZoneComponents, Key, Value),
            [Record | Acc]
        end, [], ?NAME2IP).

-spec(to_record([binary()], MappingKey, inet:ip_address()) -> dns:rr()
    when MappingKey :: {family(), binary(), binary()}).
to_record(ZoneComponents, {_Family, FwName, Label}, IP) ->
    RecordName = to_name([Label, FwName | ZoneComponents]),
    dcos_dns:dns_record(RecordName, IP).

-spec(to_name([binary()]) -> binary()).
to_name(Binaries) ->
    Bins = lists:map(fun mesos_state:domain_frag/1, Binaries),
    <<$., Name/binary>> = << <<$., Bin/binary>> || Bin <- Bins >>,
    Name.
