-module(dcos_dns_mesos_dns).
-behavior(gen_server).

-include("dcos_dns.hrl").
-include_lib("kernel/include/logger.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(MESOS_DNS_URI, "http://127.0.0.1:8123/v1/axfr").

%% API
-export([
    start_link/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3,
    handle_cast/2, handle_info/2]).

-record(state, {
    ref :: reference(),
    hash = <<>> :: binary()
}).
-type state() :: #state{}.

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    TRef = start_poll_timer(0),
    {ok, #state{ref=TRef}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({timeout, Ref, mesos_dns_poll}, #state{ref=Ref}=State) ->
    State0 = handle_poll(State),
    TRef = start_poll_timer(),
    {noreply, State0#state{ref=TRef}, hibernate};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_poll_timer() -> reference()).
start_poll_timer() ->
    Timeout = application:get_env(dcos_dns, mesos_dns_timeout, 30000),
    start_poll_timer(Timeout).

-spec(start_poll_timer(timeout()) -> reference()).
start_poll_timer(Timeout) ->
    erlang:start_timer(Timeout, self(), mesos_dns_poll).

-spec(handle_poll(state()) -> state()).
handle_poll(State) ->
    IsLeader = dcos_net_mesos_listener:is_leader(),
    handle_poll(IsLeader, State).

-spec(handle_poll(IsLeader :: boolean(), state()) -> state()).
handle_poll(false, State) ->
    State;
handle_poll(true, State) ->
    Request = {?MESOS_DNS_URI, []},
    Options = dcos_net_mesos:http_options(),
    {ok, Ref} = httpc:request(get, Request, Options, [{sync, false}]),
    Timeout = application:get_env(dcos_dns, mesos_dns_timeout, 30000),
    receive
        {http, {Ref, {error, Error}}} ->
            ?LOG_WARNING("Failed to connect to mesos-dns: ~p", [Error]),
            State;
        {http, {Ref, {{_HTTPVersion, 200, _StatusStr}, _Headers, Body}}} ->
            try get_records(Body) of Records ->
                maybe_push_zone(Records, State)
            catch Class:Error:ST ->
                ?LOG_WARNING(
                    "Failed to process mesos-dns data [~p] ~p ~p",
                    [Class, Error, ST]),
                State
            end;
        {http, {Ref, {{_HTTPVersion, Status, _StatusStr}, _Headers, Body}}} ->
            ?LOG_WARNING(
                "Failed to get data from mesos-dns [~p] ~s",
                [Status, Body]),
            State
    after Timeout ->
        ok = httpc:cancel_request(Ref),
        ?LOG_WARNING("mesos-dns connection timeout"),
        State
    end.

%%%===================================================================
%%% Handle data
%%%===================================================================

-spec(get_records(binary()) -> #{dns:dname() => [dns:dns_rr()]}).
get_records(Body) ->
    Data = jiffy:decode(Body, [return_maps]),
    Domain = maps:get(<<"Domain">>, Data, <<"mesos">>),
    Records = maps:get(<<"Records">>, Data, #{}),

    RecordsByName = #{
        ?MESOS_DOMAIN => [
            dcos_dns:soa_record(?MESOS_DOMAIN),
            dcos_dns:ns_record(?MESOS_DOMAIN)
        ]
    },
    List = [
        {<<"As">>, fun parse_ip/2, fun dcos_dns:dns_record/2},
        {<<"AAAAs">>, fun parse_ip/2, fun dcos_dns:dns_record/2},
        {<<"SRVs">>, fun parse_srv/2, fun dcos_dns:srv_record/2}
    ],
    lists:foldl(fun ({Field, ParseFun, RecordFun}, Acc) ->
        add_records(Domain, Records, Field, ParseFun, RecordFun, Acc)
    end, RecordsByName, List).

-spec(add_records(Domain, Records, Field, ParseFun, RecordFun, Acc) -> Acc
    when Domain :: dns:dname(), Records :: jiffy:json_term(),
         Field :: binary(), Acc :: #{dns:dname() => [dns:dns_rr()]},
         ParseFun :: fun((binary(), dns:dname()) -> term()),
         RecordFun :: fun((dns:dname(), term()) -> dns:dns_rr())).
add_records(Domain, Records, Field, ParseFun, RecordFun, Acc0) ->
    Data = maps:get(Field, Records, #{}),
    maps:fold(fun (DName, List, Acc) ->
        DName0 = dname(DName, Domain),
        List0 = [ParseFun(L, Domain) || L <- List],
        RRs = [RecordFun(DName0, L) || L <- lists:sort(List0)],
        mappend_list(DName0, RRs, Acc)
    end, Acc0, Data).

-spec(mappend_list(Key :: A, List :: [B], Map) -> Map
    when Map :: #{A => [B]}, A :: term(), B :: term()).
mappend_list(Key, List, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Map#{Key => List ++ Value};
        error ->
            Map#{Key => List}
    end.

-spec(dname(dns:dname(), dns:dname()) -> dns:dname()).
dname(DName, DomainName) ->
    DName0 = binary:part(DName, 0, size(DName) - size(DomainName) - 1),
    <<DName0/binary, ?MESOS_DOMAIN/binary>>.

-spec(parse_ip(binary(), dns:dname()) -> inet:ip_address()).
parse_ip(IPBin, _Domain) ->
    IPStr = binary_to_list(IPBin),
    {ok, IP} = inet:parse_strict_address(IPStr),
    IP.

-spec(parse_srv(binary(), dns:dname()) -> {dns:dname(), inet:port_number()}).
parse_srv(HostPort, Domain) ->
    [Host, Port] = binary:split(HostPort, <<":">>),
    {dname(Host, Domain), binary_to_integer(Port)}.

-spec(maybe_push_zone(#{dns:dname() => [dns:dns_rr()]}, state()) -> state()).
maybe_push_zone(Records, #state{hash=Hash}=State) ->
    case crypto:hash(sha, term_to_binary(Records)) of
        Hash -> State;
        Hash0 -> push_zone(Records, State#state{hash=Hash0})
    end.

-spec(push_zone(#{dns:dname() => [dns:dns_rr()]}, state()) -> state()).
push_zone(RecordsByName, State) ->
    Counts = lists:map(fun length/1, maps:values(RecordsByName)),
    ok = dcos_dns_mesos:push_zone(?MESOS_DOMAIN, RecordsByName),
    ?LOG_NOTICE("Mesos DNS Sync: ~p records", [lists:sum(Counts)]),
    State.
