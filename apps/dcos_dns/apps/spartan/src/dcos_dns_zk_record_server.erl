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

-dialyzer([{nowarn_function, [update_zone/1]}, no_improper_lists]).

-define(REFRESH_INTERVAL, 1000).
-define(REFRESH_MESSAGE,  refresh).

-include("dcos_dns.hrl").
-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% State record.
-record(state, {}).

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
    {ok, MasterState} = retrieve_state(),
    ok = update_zone(MasterState),
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

%% @private
%% @doc Retrieve state from the Mesos master about where the Zookeeper
%%      intances are.
retrieve_state() ->
    case os:getenv("MESOS_FIXTURE", "false") of
        "false" ->
            %% @todo Change, this is the exhibitor URL.
            Host = os:getenv("MESOS", ?EXHIBITOR_HOST),
            Url = Host ++ ?EXHIBITOR_URL,
            {ok, {{_, 200, _}, _, Body}} = httpc:request(get,
                                                         {Url, []}, [], [{body_format, binary}]),
            {ok, jsx:decode(Body, [return_maps])};
        _ ->
            Exhibitor = code:priv_dir(?APP) ++ "/exhibitor.json",
            {ok, Fixture} = file:read_file(Exhibitor),
            {ok, jsx:decode(Fixture, [return_maps])}
    end.

%% @private
update_zone(Zookeepers) ->
    ToCreate = lists:zip(lists:seq(1, 5), lists:sublist(Zookeepers ++ Zookeepers, 1, 5)),
    Records = [soa()] ++ [generate_record(R) || R <- ToCreate],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    ok = erldns_zone_cache:put_zone({<<?TLD>>, Sha, Records}),
    ok.

%% @private
soa() ->
    #dns_rr{
        name = list_to_binary(?TLD),
        type = ?DNS_TYPE_SOA,
        ttl = 3600
    }.

%% @private
generate_record({N, #{<<"hostname">> := Hostname}}) ->
    {ok, IpAddress} = inet:parse_address(binary_to_list(Hostname)),
    NewHostname = integer_to_list(N) ++ "." ++ ?TLD,
    #dns_rr{
        name = list_to_binary(NewHostname),
        type = ?DNS_TYPE_A,
        ttl = 3600,
        data = #dns_rrdata_a{ip = IpAddress}
    }.
