-module(dcos_dns_mesos_dns).
-behavior(gen_server).

-include("dcos_dns.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(MESOS_DNS_URI, "http://127.0.0.1:8123/v1/axfr").

%% API
-export([
    start_link/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

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
    {noreply, State0#state{ref=TRef}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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
            lager:warning("Failed to connect to mesos-dns: ~p", [Error]),
            State;
        {http, {Ref, {{_HTTPVersion, 200, _StatusStr}, _Headers, Body}}} ->
            try get_records(Body) of Records ->
                maybe_push_zone(Records, State)
            catch Class:Error:ST ->
                lager:warning(
                    "Failed to process mesos-dns data [~p] ~p ~p",
                    [Class, Error, ST]),
                State
            end;
        {http, {Ref, {{_HTTPVersion, Status, _StatusStr}, _Headers, Body}}} ->
            lager:warning(
                "Failed to get data from mesos-dns [~p] ~s",
                [Status, Body]),
            State
    after Timeout ->
        ok = httpc:cancel_request(Ref),
        lager:warning("mesos-dns connection timeout"),
        State
    end.

%%%===================================================================
%%% Handle data
%%%===================================================================

-spec(get_records(binary()) -> [dns:dns_rr()]).
get_records(Body) ->
    Data = jiffy:decode(Body, [return_maps]),

    MesosDNSDomain = maps:get(<<"Domain">>, Data, <<"mesos">>),
    MesosDNSRecords = maps:get(<<"Records">>, Data, #{}),

    Records =
        [ dcos_dns:soa_record(?MESOS_DOMAIN),
          dcos_dns:ns_record(?MESOS_DOMAIN) ],

    ARecords = maps:get(<<"As">>, MesosDNSRecords, #{}),
    Records0 =
        maps:fold(fun (DName, IPs, Acc) ->
            dns_records(DName, IPs, MesosDNSDomain) ++ Acc
        end, Records, ARecords),

    AAAARecords = maps:get(<<"AAAAs">>, MesosDNSRecords, #{}),
    Records1 =
        maps:fold(fun (DName, IPs, Acc) ->
            dns_records(DName, IPs, MesosDNSDomain) ++ Acc
        end, Records0, AAAARecords),

    SRVRecords = maps:get(<<"SRVs">>, MesosDNSRecords, #{}),
    Records2 =
        maps:fold(fun (DName, HPs, Acc) ->
            srv_records(DName, HPs, MesosDNSDomain) ++ Acc
        end, Records1, SRVRecords),

    Records2.

-spec(dname(binary(), binary()) -> binary()).
dname(DName, DomainName) ->
    DName0 = binary:part(DName, 0, size(DName) - size(DomainName) - 1),
    <<DName0/binary, ?MESOS_DOMAIN/binary>>.

-spec(parse_ips([binary()]) -> [inet:ip_address()]).
parse_ips(IPs) ->
    lists:map(fun parse_ip/1, IPs).

-spec(parse_ip(binary()) -> inet:ip_address()).
parse_ip(IPBin) ->
    IPStr = binary_to_list(IPBin),
    {ok, IP} = inet:parse_strict_address(IPStr),
    IP.

-spec(dns_records(dns:dname(), IPs, Domain) -> [dns:dns_rr()]
    when IPs :: [binary()], Domain :: binary()).
dns_records(DName, IPs, MesosDNSDomain) ->
    IPs0 = parse_ips(IPs),
    DName0 = dname(DName, MesosDNSDomain),
    dcos_dns:dns_records(DName0, IPs0).

-spec(srv_records(dns:dname(), HPs, Domain) -> [dns:dns_rr()]
    when HPs :: [binary()], Domain :: binary()).
srv_records(DName, HPs, MesosDNSDomain) ->
    DName0 = dname(DName, MesosDNSDomain),
    lists:map(fun (HP) ->
        [Host, Port] = binary:split(HP, <<":">>),
        Host0 = dname(Host, MesosDNSDomain),
        Port0 = binary_to_integer(Port),
        dcos_dns:srv_record(DName0, {Host0, Port0})
    end, HPs).

-spec(maybe_push_zone([dns:dns_rr()], state()) -> state()).
maybe_push_zone(Records, #state{hash=Hash}=State) ->
    Records0 = lists:sort(Records),
    case crypto:hash(sha, term_to_binary(Records0)) of
        Hash -> State;
        Hash0 -> push_zone(Records, State#state{hash=Hash0})
    end.

-spec(push_zone([dns:dns_rr()], state()) -> state()).
push_zone(Records, State) ->
    case dcos_dns_mesos:push_zone(?MESOS_DOMAIN, Records) of
        {ok, [], []} -> State;
        {ok, NewRRs, OldRRs} ->
            lager:notice(
                "Mesos DNS Sync: ~p reconds were added, ~p reconds were removed",
                [length(NewRRs), length(OldRRs)]),
            State
    end.
