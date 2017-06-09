-module(dcos_dns_zk_record_server).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

%% API
-export([start_link/0,
         start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% 10 seconds
-define(REFRESH_INTERVAL, 10000).
-define(REFRESH_MESSAGE,  refresh).

-include("dcos_dns.hrl").
-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% State record.
-record(state, {}).

-define(ZOOKEEPER_RECORDS, 5).

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

init([]) ->
    update_zone([]),
    timer:send_after(0, ?REFRESH_MESSAGE),
    {ok, #state{}}.

handle_call(?REFRESH_MESSAGE, _FRom, State0) ->
    {noreply, State1} = handle_info(?REFRESH_MESSAGE, State0),
    {reply, ok, State1};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

handle_info(?REFRESH_MESSAGE, State) ->
    case application:get_env(?APP, mesos_resolvers, []) of
        [] ->
            ok;
        ResolversWithPorts ->
            Resolvers = [ResolverAddr || {ResolverAddr, _ResolverPort} <- ResolversWithPorts],
            ok = update_zone(Resolvers)
    end,
    timer:send_after(?REFRESH_INTERVAL, ?REFRESH_MESSAGE),
    {noreply, State};
handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


%% @private
-spec update_zone(Zookeepers :: [inet:ip4_address()]) -> ok.
update_zone([]) ->
    Records = Records = [soa()] ++ ns_records(),
    ok = push_records(Records);
update_zone(Zookeepers) ->
    RepeatCount = ceiling(?ZOOKEEPER_RECORDS / length(Zookeepers)),
    RepeatedZookeepers = lists:flatten(lists:duplicate(RepeatCount, Zookeepers)),
    ToCreate = lists:zip(lists:seq(1, ?ZOOKEEPER_RECORDS), lists:sublist(RepeatedZookeepers, ?ZOOKEEPER_RECORDS)),
    Records = [soa()] ++ ns_records() ++ [generate_record(R) || R <- ToCreate],
    ok = push_records(Records),
    ok.

push_records(Records) ->
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
            serial = 1,
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
-spec(generate_record({N :: non_neg_integer(), IPAddress :: inet:ip4_address()}) -> dns:rr()).
generate_record({N, IpAddress}) ->
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
