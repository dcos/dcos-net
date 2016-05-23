-module(dcos_dns_zk_record_server).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

%% API
-export([start_link/0,
         start_link/1]).

-ifdef(TEST).
-export([generate_fixture_mesos_zone/0]).
-endif.

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% Required because JSON response Exhibitor is a list of objects in
%% JSON, and the specification for the decode call of jsx assumes a
%% wrapping object of records.
-dialyzer([{nowarn_function, [update_zone/1,
                              soa/0,
                              ns_records/0,
                              ns_name/0,
                              generate_record/1,
                              ceiling/1]}]).

%% 2 minutes
-define(REFRESH_INTERVAL, 120000).
-define(REFRESH_MESSAGE,  refresh).

-include("dcos_dns.hrl").
-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% State record.
-record(state, {}).

-define(ZOOKEEPER_RECORDS, 5).
-define(DEFAULT_EXHIBITOR_URL, "http://master.mesos:8181/exhibitor/v1/cluster/status").

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    start_link([]).

%% @doc Start and link to calling process.
-spec start_link(list())-> {ok, pid()} | ignore | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    timer:send_after(0, ?REFRESH_MESSAGE),
    {ok, #state{}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.

%% @private
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(?REFRESH_MESSAGE, State) ->
    timer:send_after(?REFRESH_INTERVAL, ?REFRESH_MESSAGE),
    case retrieve_state() of
        {ok, MasterState} ->
            ok = update_zone(MasterState);
        {error, _} ->
            ok
    end,
    {noreply, State};
handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-ifdef(TEST).

%% @private
retrieve_state() ->
    generate_fixture_response().

-else.

%% @private
%% @doc Retrieve state from the Mesos master about where the Zookeeper
%%      instances are.
-spec retrieve_state() -> {ok, [map()]} | {error, unavailable}.
retrieve_state() ->
    case os:getenv("MESOS_FIXTURE", "false") of
        "false" ->
            Url = application:get_env(?APP, exhibitor_url, ?DEFAULT_EXHIBITOR_URL),
            case httpc:request(get, {Url, []}, [], [{body_format, binary}]) of
                {ok, {{_, 200, _}, _, Body}} ->
                    DecodedJSON = jsx:decode(Body, [return_maps]),
                    true = is_list(DecodedJSON),
                    {ok, DecodedJSON};
                Error ->
                    lager:info("Failed to retrieve information from exhibitor: ~p", [Error]),
                    {error, unavailable}
            end;
        _ ->
            generate_fixture_response()
    end.

-endif.

%% @private
generate_fixture_response() ->
    Exhibitor = code:priv_dir(?APP) ++ "/exhibitor.json",
    {ok, Fixture} = file:read_file(Exhibitor),
    {ok, jsx:decode(Fixture, [return_maps])}.

-ifdef(TEST).

%% @private
generate_fixture_mesos_zone() ->
    SOA = #dns_rr{
        name = list_to_binary("mesos"),
        type = ?DNS_TYPE_SOA,
        ttl = 3600
    },
    RR = #dns_rr{
        name = list_to_binary("master.mesos"),
        type = ?DNS_TYPE_A,
        ttl = 3600,
        data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
    },
    Records = [SOA, RR],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    ok = erldns_zone_cache:put_zone({<<"mesos">>, Sha, Records}),
    ok.

-endif.

%% @private
-spec update_zone([#{}]) -> ok.
update_zone(Zookeepers) ->
    RepeatCount = ceiling(?ZOOKEEPER_RECORDS / length(Zookeepers)),
    RepeatedZookeepers = lists:flatten(lists:duplicate(RepeatCount, Zookeepers)),
    ToCreate = lists:zip(lists:seq(1, ?ZOOKEEPER_RECORDS), lists:sublist(RepeatedZookeepers, ?ZOOKEEPER_RECORDS)),
    Records = [soa()] ++ ns_records() ++ [generate_record(R) || R <- ToCreate],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    ok = erldns_zone_cache:put_zone({<<?TLD>>, Sha, Records}),
    ok.

%% @private
soa() ->
    #dns_rr{
        name = list_to_binary(?TLD),
        type = ?DNS_TYPE_SOA,
        ttl = 3600,
        data = #dns_rrdata_soa{
            mname = ns_name(),
            rname = <<"support.mesosphere.com">>,
            serial = erlang:unique_integer([positive, monotonic]),
            refresh = 600,
            retry = 300,
            expire = 86400,
            minimum = 1
        }
    }.

ns_records() ->
    [
        #dns_rr{
            name = ns_name(),
            type = ?DNS_TYPE_A,
            ttl = 3600,
            %% The IANA Blackhole server
            data = #dns_rrdata_a{ip = {192, 175, 48, 6}}
        },
        #dns_rr{
            name = list_to_binary(?TLD),
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = ns_name()
            }
        }
    ]
    .

ns_name() ->
    list_to_binary(string:join(["ns", ?TLD], ".")).

%% @private
generate_record({N, #{<<"hostname">> := Hostname}}) ->
    {ok, IpAddress} = inet:parse_address(binary_to_list(Hostname)),
    NewHostname = "zk-" ++ integer_to_list(N) ++ "." ++ ?TLD,
    #dns_rr{
        name = list_to_binary(NewHostname),
        type = ?DNS_TYPE_A,
        ttl = 5,
        data = #dns_rrdata_a{ip = IpAddress}
    }.

%% Borrowed from: https://erlangcentral.org/wiki/index.php?title=Floating_Point_Rounding
%% @private
ceiling(X) ->
    T = trunc(X),
    case X - T == 0 of
        true -> T;
        false -> T + 1
    end.
