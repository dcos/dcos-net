-module(dcos_l4lb_ipset_mgr).

-include_lib("gen_netlink/include/netlink.hrl").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    get_entries/0,
    get_entries/1,
    add_entries/2,
    remove_entries/2,
    cleanup/0,
    init_metrics/0
]).

%% gen_server callbacks
-export([init/1, handle_continue/2,
    handle_call/3, handle_cast/2]).

-export_type([entry/0]).

-type entry() :: dcos_l4lb_mesos_poller:key().

-record(state, {
    netlink :: pid()
}).

-define(IPSET_PROTOCOL, 6).
-define(IPSET_TYPE, "hash:ip,port").
-define(IPSET_NAME, "dcos-l4lb").
-define(IPSET_NAME_IPV6, "dcos-l4lb-ipv6").


-spec(get_entries() -> [entry()]).
get_entries() ->
    % NOTE: FOR DEBUG PURPOSE ONLY.
    {ok, Pid} = start_link(),
    try
        get_entries(Pid)
    after
        erlang:unlink(Pid),
        gen_server:cast(Pid, stop)
    end.

-spec(get_entries(pid()) -> [entry()]).
get_entries(Pid) ->
    call(Pid, get_entries).

-spec(add_entries(pid(), [entry()]) -> ok).
add_entries(Pid, Entries) ->
    call(Pid, {add_entries, Entries}).

-spec(remove_entries(pid(), [entry()]) -> ok).
remove_entries(Pid, Entries) ->
    call(Pid, {remove_entries, Entries}).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, {}, {continue, dcos_l4lb_config:ipset_enabled()}}.

handle_continue(false, {}) ->
    cleanup(),
    {noreply, disabled};
handle_continue(true, {}) ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_NETFILTER),
    {ok, ?IPSET_PROTOCOL} = get_protocol_version(Pid),
    {ok, []} = maybe_create_ipset(Pid, inet),
    {ok, _} = maybe_add_iptables_rules(inet),
    {ok, []} = maybe_create_ipset(Pid, inet6),
    {ok, _} = maybe_add_iptables_rules(inet6),
    {noreply, #state{netlink=Pid}}.

handle_call(get_entries, _From, disabled) ->
    {reply, [], disabled};
handle_call(_Request, _From, disabled) ->
    {reply, ok, disabled};
handle_call(get_entries, _From, #state{netlink=Pid}=State) ->
    {ok, EntriesIPv4} = get_entries(Pid, ?IPSET_NAME),
    {ok, EntriesIPv6} = get_entries(Pid, ?IPSET_NAME_IPV6),
    {reply, EntriesIPv4 ++ EntriesIPv6, State};
handle_call({add_entries, Entries}, _From, #state{netlink=Pid}=State) ->
    lists:foreach(fun ({Protocol, IP, Port}) ->
        {ok, []} = add_entry(Pid, Protocol, IP, Port)
    end, Entries),
    {reply, ok, State};
handle_call({remove_entries, Entries}, _From, #state{netlink=Pid}=State) ->
    lists:foreach(fun ({Protocol, IP, Port}) ->
        {ok, []} = del_entry(Pid, Protocol, IP, Port)
    end, Entries),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Request, State) ->
    {noreply, State}.

%%%===================================================================
%%% Initialize ipset protocol
%%%===================================================================

-spec(get_protocol_version(pid()) ->
    {ok, non_neg_integer()} | {error, atom() | non_neg_integer()}).
get_protocol_version(Pid) ->
    case request(Pid, protocol, [request], [{protocol, ?IPSET_PROTOCOL}]) of
        {ok, [{ipset, protocol, _Flags, _Seq, _Pid, {inet, 0, 0, Response}}]} ->
            case get_protocol_versions(Response) of
                {ok, ?IPSET_PROTOCOL} ->
                    {ok, ?IPSET_PROTOCOL};
                {ok, Ver} ->
                    lager:alert(
                        "ipset protocol (ver. ~p) is not supported: ~p",
                        [?IPSET_PROTOCOL, Ver]),
                    {error, Ver};
                {ok, Ver, VerMin}
                    when Ver >= ?IPSET_PROTOCOL,
                         VerMin =< ?IPSET_PROTOCOL ->
                    {ok, ?IPSET_PROTOCOL};
                {ok, Ver, VerMin} ->
                    lager:alert(
                        "ipset protocol (ver. ~p) is not supported: ~p, ~p",
                        [?IPSET_PROTOCOL, Ver, VerMin]),
                    {error, Ver};
                error ->
                    lager:alert("Failed to initialize ipset"),
                    {error, no_version}
            end;
        {error, Error, _Response} ->
            {error, Error}
    end.

-spec(get_protocol_versions(term()) -> {ok, Ver} | {ok, Ver, Ver} | error
    when Ver :: non_neg_integer()).
get_protocol_versions(Response) ->
    case lists:keyfind(protocol, 1, Response) of
        {protocol, Ver} ->
            case lists:keyfind(protocol_min, 1, Response) of
                {protocol_min, VerMin} ->
                    {ok, Ver, VerMin};
                false ->
                    {ok, Ver}
            end;
        false ->
            error
    end.

-spec(get_supported_revision(pid(), string(), family()) ->
    {ok, non_neg_integer()} | {error, atom() | non_neg_integer()}).
get_supported_revision(Pid, Type, Family) ->
    Msg = [{protocol, ?IPSET_PROTOCOL}, {typename, Type}, {family, Family}],
    case request(Pid, type, [request], Msg) of
        {ok, [{ipset, type, _Flags, _Seq, _Pid, {inet, 0, 0, Response}}]} ->
            case lists:keyfind(revision, 1, Response) of
                {revision, Revision} -> {ok, Revision};
                false -> {error, not_found}
            end;
        {error, Error, _Response} ->
            {error, Error}
    end.

%%%===================================================================
%%% Create ipset
%%%===================================================================

-define(IPSET_FLAG_WITH_COUNTERS, 2#1000).
-define(IPSET_REVISION_WITH_COUNTERS, 2).

-spec(maybe_create_ipset(pid(), family()) ->
    {ok, term()} | {error, atom() | non_neg_integer(), term()}).
maybe_create_ipset(Pid, Family) ->
    IsIPv6Enabled = dcos_l4lb_config:ipv6_enabled(),
    case Family of
        inet6 when not IsIPv6Enabled ->
            {ok, []};
        inet ->
            create_ipset(Pid, Family, ?IPSET_NAME, ?IPSET_TYPE);
        inet6 ->
            create_ipset(Pid, Family, ?IPSET_NAME_IPV6, ?IPSET_TYPE)
    end.

-spec(create_ipset(pid(), family(), Name :: string(), Type :: string()) ->
    {ok, term()} | {error, atom() | non_neg_integer(), term()}).
create_ipset(Pid, Family, Name, Type) ->
    {ok, Rev} = get_supported_revision(Pid, Type, Family),
    request(Pid, create, [atomic, ack, request], [
        {protocol, ?IPSET_PROTOCOL},
        {setname, Name},
        {typename, Type},
        {revision, min(?IPSET_REVISION_WITH_COUNTERS, Rev)},
        {family, Family},
        {data,
            case Rev >= ?IPSET_REVISION_WITH_COUNTERS of
                true -> [{cadt_flags, ?IPSET_FLAG_WITH_COUNTERS}];
                false -> []
            end}
    ]).

%%%===================================================================
%%% IPTables rules
%%%===================================================================

-spec(maybe_add_iptables_rules(family()) ->
    {ok, binary()} | {error, atom() | {exit_status, non_neg_integer()}}).
maybe_add_iptables_rules(Family) ->
    IsIPv6Enabled = dcos_l4lb_config:ipv6_enabled(),
    case Family of
        inet6 when not IsIPv6Enabled ->
            {ok, <<>>};
        inet ->
            add_iptables_rules(<<"/sbin/iptables">>, ?IPSET_NAME);
        inet6 ->
            add_iptables_rules(<<"/sbin/ip6tables">>, ?IPSET_NAME_IPV6)
    end.

-spec(add_iptables_rules(Command :: binary(), Name :: string()) ->
    {ok, binary()} | {error, atom() | {exit_status, non_neg_integer()}}).
add_iptables_rules(Command, Name) ->
    add_iptables_rules(Command, Name, <<"OUTPUT">>),
    add_iptables_rules(Command, Name, <<"PREROUTING">>).

-spec(add_iptables_rules(binary(), string(), binary()) ->
    {ok, binary()} | {error, atom() | {exit_status, non_neg_integer()}}).
add_iptables_rules(Command, Name, Chain) ->
    case add_iptables_rules(Command, Name, <<"-C">>, Chain) of
        {ok, Output} ->
            {ok, Output};
        {error, _Code} ->
            add_iptables_rules(Command, Name, <<"-I">>, Chain)
    end.

-spec(add_iptables_rules(binary(), string(), binary(), binary()) ->
    {ok, binary()} | {error, atom() | {exit_status, non_neg_integer()}}).
add_iptables_rules(Command, Name, Action, Chain) ->
    IPSet = list_to_binary(Name),
    dcos_net_utils:system([
        Command,
        <<"-w">>, <<"-t">>, <<"nat">>, Action, Chain,
        <<"-m">>, <<"set">>, <<"--match-set">>, IPSet, <<"dst,dst">>,
        <<"-m">>, <<"comment">>, <<"--comment">>, <<"Skip DC/OS L4LB traffic">>,
        <<"-j">>, <<"RETURN">>]).

%%%===================================================================
%%% Ipset entries functions
%%%===================================================================

-spec(add_entry(pid(), protocol(), inet:ip_address(), inet:port_number()) ->
    {ok, []} | {error, atom() | non_neg_integer(), term()}).
add_entry(Pid, Protocol, IP, Port) ->
    cmd_entry(Pid, add, Protocol, IP, Port).

-spec(del_entry(pid(), protocol(), inet:ip_address(), inet:port_number()) ->
    {ok, []} | {error, atom() | non_neg_integer(), term()}).
del_entry(Pid, Protocol, IP, Port) ->
    cmd_entry(Pid, del, Protocol, IP, Port).

-spec(cmd_entry(pid(), Command, Protocol, IP, Port) ->
    {ok, []} | {error, atom() | non_neg_integer(), term()}
        when Command :: add | del, Protocol :: protocol(),
             IP :: inet:ip_address(), Port :: inet:port_number()).
cmd_entry(Pid, Command, Protocol, IP, Port) ->
    Family = dcos_l4lb_app:family(IP),
    Name =
        case Family of
            inet -> ?IPSET_NAME;
            inet6 -> ?IPSET_NAME_IPV6
        end,
    request(Pid, Command, [ack, request], [
        {protocol, ?IPSET_PROTOCOL},
        {setname, Name},
        {data, [
            {ip, [{Family, IP}]},
            {port, Port},
            {proto, Protocol}
        ]}
    ]).

-spec(get_entries(pid(), Name :: string()) ->
    {ok, [entry()]} | {error, atom() | non_neg_integer(), term()}).
get_entries(Pid, Name) ->
    Msg = [{protocol, ?IPSET_PROTOCOL}, {setname, Name}],
    case request(Pid, list, [match, root, ack, request], Msg) of
        {ok, Response} ->
            {ok, parse_entries(Response)};
        {error, enoent, _Response} ->
            {ok, []};
        {error, Error, _Response} ->
            {error, Error}
    end.

-spec(parse_entries(Response :: term()) -> [entry()]).
parse_entries(Response) ->
    lists:flatmap(
        fun ({ipset, list, _Flags, _Seq, _Pid, {inet, 0, 0, Info}}) ->
            {adt, ADT} = lists:keyfind(adt, 1, Info),
            lists:map(fun ({data, Data}) ->
                {ip, [{_Family, IP}]} = lists:keyfind(ip, 1, Data),
                {port, Port} = lists:keyfind(port, 1, Data),
                {proto, Protocol} = lists:keyfind(proto, 1, Data),
                {Protocol, IP, Port}
            end, ADT)
        end, Response).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(request(pid(), Command :: atom(), Flags :: [atom()], Msg :: term()) ->
    {ok, term()} | {error, atom() | non_neg_integer(), term()}).
request(Pid, Command, Flags, Msg) ->
    Args = [Pid, ?NETLINK_NETFILTER, ipset, Command, Flags, {inet, 0, 0, Msg}],
    case apply(gen_netlink_client, request, Args) of
        {ok, Response} ->
            {ok, Response};
        {error, eexist, _Response} ->
            % NOTE: some kernel versions ignore a missing `match` flag for
            % ipset protocol and return an `eexist` error.
            {ok, []};
        {error, Code, Response} ->
            Error = get_error(Code),
            {error, Error, Response}
    end.

-spec(get_error(file:posix() | non_neg_integer()) ->
    atom() | non_neg_integer()).
get_error(Code) ->
    % Link: git://git.netfilter.org/ipset.git
    % File: include/libipset/linux_ip_set.h
    Mapping = #{
        4097 => ipset_err_protocol,
        4098 => ipset_err_find_type,
        4099 => ipset_err_max_sets,
        4100 => ipset_err_busy,
        4101 => ipset_err_exist_setname2,
        4102 => ipset_err_type_mismatch,
        4103 => ipset_err_exist,
        4104 => ipset_err_invalid_cidr,
        4105 => ipset_err_invalid_netmask,
        4106 => ipset_err_invalid_family,
        4107 => ipset_err_timeout,
        4108 => ipset_err_referenced,
        4109 => ipset_err_ipaddr_ipv4,
        4110 => ipset_err_ipaddr_ipv6,
        4111 => ipset_err_counter,
        4112 => ipset_err_comment,
        4113 => ipset_err_invalid_markmask,
        4114 => ipset_err_skbinfo,
        4352 => ipset_err_type_specific
    },
    maps:get(Code, Mapping, Code).

%%%===================================================================
%%% Cleanup function
%%%===================================================================

-spec(cleanup() -> ok).
cleanup() ->
    add_iptables_rules(
        <<"/sbin/iptables">>, ?IPSET_NAME,
        <<"-D">>, <<"OUTPUT">>),
    add_iptables_rules(
        <<"/sbin/iptables">>, ?IPSET_NAME,
        <<"-D">>, <<"PREROUTING">>),
    dcos_net_utils:system([
        <<"/sbin/ipset">>, <<"destroy">>,
        list_to_binary(?IPSET_NAME)
    ]),
    add_iptables_rules(
        <<"/sbin/ip6tables">>, ?IPSET_NAME_IPV6,
        <<"-D">>, <<"OUTPUT">>),
    add_iptables_rules(
        <<"/sbin/ip6tables">>, ?IPSET_NAME_IPV6,
        <<"-D">>, <<"PREROUTING">>),
    dcos_net_utils:system([
        <<"/sbin/ipset">>, <<"destroy">>,
        list_to_binary(?IPSET_NAME_IPV6)
    ]),
    ok.

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(call(pid(), term()) -> term()).
call(Pid, Request) ->
    prometheus_summary:observe_duration(
        l4lb, ipset_duration_seconds, [],
        fun () -> gen_server:call(Pid, Request) end).

-spec(init_metrics() -> ok).
init_metrics() ->
    prometheus_summary:new([
        {registry, l4lb},
        {name, ipset_duration_seconds},
        {help, "The time spent prossing IPSet configuration."}]).
