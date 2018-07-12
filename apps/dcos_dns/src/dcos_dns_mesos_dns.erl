-module(dcos_dns_mesos_dns).
-behavior(gen_server).

-include("dcos_dns.hrl").
-include_lib("dns/include/dns.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(MESOS_DNS_URI, "http://127.0.0.1:8123/v1/axfr").
-define(DCOS_DNS_TTL, 5).

%% API
-export([
    start_link/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-record(state, {
    ref :: reference()
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
            lager:warning("mesos-dns connection error: ~p", [Error]),
            State;
        {http, {Ref, {{_HTTPVersion, 200, _StatusStr}, _Headers, Body}}} ->
            try
                Data = jiffy:decode(Body, [return_maps]),
                handle_data(Data, State)
            catch Class:Error ->
                lager:warning("mesos-dns bad json ~p:~p", [Class, Error]),
                State
            end;
        {http, {Ref, {{_HTTPVersion, Status, _StatusStr}, _Headers, Body}}} ->
            lager:warning("mesos-dns error [~p] ~s", [Status, Body]),
            State
    after Timeout ->
        ok = httpc:cancel_request(Ref),
        lager:warning("mesos-dns connection timeout"),
        State
    end.

%%%===================================================================
%%% Handle data
%%%===================================================================

-spec(handle_data(jiffy:object(), state()) -> state()).
handle_data(Data, State) ->
    MesosDNSDomain = maps:get(<<"Domain">>, Data, <<"mesos">>),
    MesosDNSRecords = maps:get(<<"Records">>, Data, #{}),

    Records = zone_records(?MESOS_DOMAIN),

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

    case push_zone(Records2) of
        {ok, [], []} -> State;
        {ok, NewRRs, OldRRs} ->
            lager:notice(
                "Update ~s: ~p reconds were added, ~p reconds were removed",
                [?MESOS_DOMAIN, length(NewRRs), length(OldRRs)]),
            State
    end.

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
    dcos_dns_mesos:dns_records(DName0, IPs0).

-spec(srv_records(dns:dname(), HPs, Domain) -> [dns:dns_rr()]
    when HPs :: [binary()], Domain :: binary()).
srv_records(DName, HPs, MesosDNSDomain) ->
    DName0 = dname(DName, MesosDNSDomain),
    lists:map(fun (HP) ->
        [Host, Port] = binary:split(HP, <<":">>),
        Host0 = dname(Host, MesosDNSDomain),
        Port0 = binary_to_integer(Port),
        srv_record(DName0, Host0, Port0)
    end, HPs).

-spec(push_zone([dns:dns_rr()]) ->
    {ok, New :: [dns:dns_rr()], Old :: [dns:dns_rr()]}).
push_zone(Records) ->
    dcos_dns_mesos:push_zone(?MESOS_DOMAIN, Records).

%%%===================================================================
%%% DNS functions
%%%===================================================================

-spec(srv_record(dns:dname(), dns:dname(), inet:port_number()) -> dns:rr()).
srv_record(DName, Host, Port) ->
    #dns_rr{
        name = DName,
        type = ?DNS_TYPE_SRV,
        ttl = ?DCOS_DNS_TTL,
        data = #dns_rrdata_srv{
            target = Host,
            port = Port,
            weight = 1,
            priority = 1
        }
    }.

-spec(zone_records(dns:dname()) -> [dns:dns_rr()]).
zone_records(ZoneName) ->
    [
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_SOA,
            ttl = 3600,
            data = #dns_rrdata_soa{
                mname = <<"ns.spartan">>,
                rname = <<"support.mesosphere.com">>,
                serial = 1,
                refresh = 60,
                retry = 180,
                expire = 86400,
                minimum = 1
            }
        },
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ].
