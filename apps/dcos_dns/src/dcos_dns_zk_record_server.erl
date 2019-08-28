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

-include_lib("kernel/include/logger.hrl").
-include("dcos_dns.hrl").

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
    self() ! init,
    {ok, #state{}}.

handle_call(?REFRESH_MESSAGE, _FRom, State0) ->
    {noreply, State1} = handle_info(?REFRESH_MESSAGE, State0),
    {reply, ok, State1};
handle_call(Msg, _From, State) ->
    ?LOG_WARNING("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    ?LOG_WARNING("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

handle_info(init, State) ->
    update_zone([]),
    self() ! ?REFRESH_MESSAGE,
    {noreply, State};
handle_info(?REFRESH_MESSAGE, State) ->
    case dcos_dns_config:mesos_resolvers() of
        [] ->
            ok;
        ResolversWithPorts ->
            Resolvers = [ResolverAddr || {ResolverAddr, _ResolverPort} <- ResolversWithPorts],
            ok = update_zone(Resolvers)
    end,
    timer:send_after(?REFRESH_INTERVAL, ?REFRESH_MESSAGE),
    {noreply, State};
handle_info(Msg, State) ->
    ?LOG_WARNING("Unhandled messages: ~p", [Msg]),
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
    ok = dcos_dns:push_zone(<<?TLD>>, []);
update_zone(Zookeepers) ->
    RepeatCount = ceiling(?ZOOKEEPER_RECORDS / length(Zookeepers)),
    RepeatedZookeepers = lists:flatten(lists:duplicate(RepeatCount, Zookeepers)),
    ToCreate = lists:zip(lists:seq(1, ?ZOOKEEPER_RECORDS), lists:sublist(RepeatedZookeepers, ?ZOOKEEPER_RECORDS)),
    Records = [generate_record(R) || R <- ToCreate],
    ok = dcos_dns:push_zone(<<?TLD>>, Records).


%% @private
-spec(generate_record({N :: non_neg_integer(), IPAddress :: inet:ip4_address()}) -> dns:rr()).
generate_record({N, IpAddress}) ->
    NewHostname = "zk-" ++ integer_to_list(N) ++ "." ++ ?TLD,
    dcos_dns:dns_record(list_to_binary(NewHostname), IpAddress).

%% Borrowed from: https://erlangcentral.org/wiki/index.php?title=Floating_Point_Rounding
%% @private
ceiling(X) ->
    T = trunc(X),
    case X - T == 0 of
        true -> T;
        false -> T + 1
    end.
