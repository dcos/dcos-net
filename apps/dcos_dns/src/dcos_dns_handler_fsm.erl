-module(dcos_dns_handler_fsm).
-author("sdhillon").
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API

-define(SERVER, ?MODULE).

-define(TIMEOUT, 5000).

-include("dcos_dns.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-type error() :: term().

%% State callbacks
-export([execute/2,
         wait_for_reply/2,
         waiting_for_rest_replies/2]).

%% Private utility functions
-export([resolve/3]).

%% API
-export([start_link/2]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-type dns_message() :: #dns_message{}.
-type from_module() :: dcos_dns_udp_server | dcos_dns_tcp_handler.
-type from_key() :: {inet:ip4_address(), inet:port_number()} | pid().
-type from() :: {from_module(), from_key()}.
-type outstanding_upstream() :: {upstream(), pid()}.

-record(state, {
    from = erlang:error() :: from(),
    dns_message :: dns_message(),
    data = erlang:error() :: binary(),
    outstanding_upstreams = [] :: [outstanding_upstream()],
    send_query_time :: integer(),
    start_timestamp = undefined :: os:timestamp()
}).

-spec(start_link(from(), binary()) -> {ok, pid()} | ignore | {error, error()}).
start_link(From, Data) ->
    gen_fsm:start_link(?MODULE, [From, Data], []).

%% @private
init([From, Data]) ->
    %% My fate is sealed
    %% I must die
    %% This is a result of DCOS-5858... Bugs happen.
    timer:send_after(?TIMEOUT * 2, timeout),
    timer:exit_after(?TIMEOUT * 3, timeout_kill),
    timer:kill_after(?TIMEOUT * 4),
    process_flag(trap_exit, true),
    case From of
        {dcos_dns_tcp_handler, Pid} when is_pid(Pid) ->
            %% Link handler pid.
            link(Pid);
        _ ->
            %% Don't link.
            ok
    end,
    {ok, execute, #state{from=From, data=Data}, 0}.

%% @private
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%% @private
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%% @private
handle_info(timeout, wait_for_reply, State) ->
    reply_fail(State),
    mark_rest_as_failed(State),
    {stop, normal, State};
handle_info(timeout, waiting_for_rest_replies, State) ->
    mark_rest_as_failed(State),
    {stop, normal, State};
handle_info({'EXIT', _FromPid, normal}, StateName, State) ->
    {next_state, StateName, State};
handle_info({'EXIT', FromPid, Reason}, StateName,
            #state{outstanding_upstreams=OutstandingUpstreams0}=State) ->
    OutstandingUpstreams =
        case lists:keyfind(FromPid, 2, OutstandingUpstreams0) of
            false ->
                lager:warning("Error, unrecognized late response, reason: ~p", [Reason]),
                OutstandingUpstreams0;
            {Upstream, _Pid} ->
                dcos_dns_metrics:update([?MODULE, Upstream, failures], 1, ?SPIRAL),
                lists:keydelete(Upstream, 1, OutstandingUpstreams0)

        end,
    {next_state, StateName, State#state{outstanding_upstreams=OutstandingUpstreams}, ?TIMEOUT};
handle_info(Info, StateName, State) ->
    lager:debug("Got info: ~p", [Info]),
    {next_state, StateName, State, ?TIMEOUT}.

%% @private
terminate(timeout_kill, _StateName, State) ->
    dcos_dns_metrics:update([?APP, timeout_kill], 1, ?SPIRAL),
    mark_rest_as_failed(State),
    ok;
terminate(_Reason, _StateName, #state{from=From}) ->
    case From of
        {dcos_dns_tcp_handler, Pid} when is_pid(Pid) ->
            %% Unlink handler pid.
            unlink(Pid);
        _ ->
            %% Don't link.
            ok
    end,
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

execute(timeout, State = #state{data = Data}) ->
    %% The purpose of this pattern match is to bail as soon as possible,
    %% in case the data we've received is 'corrupt'
    DNSMessage = #dns_message{} = dns:decode_message(Data),
    Questions = DNSMessage#dns_message.questions,
    State1 = State#state{dns_message = DNSMessage, send_query_time = erlang:monotonic_time()},
    case dcos_dns_router:upstreams_from_questions(Questions) of
        [] ->
            dcos_dns_metrics:update([?APP, no_upstreams_available], 1, ?SPIRAL),
            reply_fail(State1),
            {stop, normal, State};
        Upstreams0 ->
            StartTimestamp = os:timestamp(),
            QueryUpstreams = take_upstreams(Upstreams0),
            OutstandingUpstreams = lists:map(fun(Upstream) ->
                            Pid = spawn_link(?MODULE,
                                             resolve,
                                             [self(), Upstream, State]),
                            {Upstream, Pid}
                            end, QueryUpstreams),
            State2 = State1#state{start_timestamp=StartTimestamp,
                                  outstanding_upstreams=OutstandingUpstreams},
            {next_state, wait_for_reply, State2, ?TIMEOUT}
    end.

%% The first reply.
wait_for_reply({upstream_reply, Upstream, ReplyData},
               #state{start_timestamp=StartTimestamp}=State) ->
    %% Match to force quick failure.
    #dns_message{} = dns:decode_message(ReplyData),

    %% Reply immediately.
    reply_success(ReplyData, State),

    %% Then, record latency metrics after response.
    Timestamp = os:timestamp(),
    TimeDiff = timer:now_diff(Timestamp, StartTimestamp),
    dcos_dns_metrics:update([?MODULE, Upstream, latency], TimeDiff, ?HISTOGRAM),

    maybe_done(Upstream, State);
%% Timeout waiting for messages, assume all upstreams have timed out.
wait_for_reply(timeout, State) ->
    reply_fail(State),
    dcos_dns_metrics:update([?APP, upstreams_failed], 1, ?SPIRAL),
    mark_rest_as_failed(State),
    {stop, normal, State}.

waiting_for_rest_replies({upstream_reply, Upstream, _ReplyData},
                         #state{start_timestamp=StartTimestamp}=State) ->
    %% Record latency metrics after response.
    Timestamp = os:timestamp(),
    TimeDiff = timer:now_diff(Timestamp, StartTimestamp),
    dcos_dns_metrics:update([?MODULE, Upstream, latency], TimeDiff, ?HISTOGRAM),

    %% Ignore reply data.
    maybe_done(Upstream, State);
waiting_for_rest_replies(timeout,
                         #state{outstanding_upstreams=Upstreams}=State) ->
    lists:foreach(fun({Upstream, _Pid}) ->
                        dcos_dns_metrics:update([?MODULE, Upstream, failures], 1, ?SPIRAL)
                  end, Upstreams),
    {stop, normal, State}.


%% Internal API
%% Kind of ghetto. Fix it.
%% @private
maybe_done(Upstream, #state{outstanding_upstreams=OutstandingUpstreams0}=State) ->

    dcos_dns_metrics:update([?MODULE, Upstream, successes], 1, ?SPIRAL),
    Now = erlang:monotonic_time(),
    OutstandingUpstreams = lists:keydelete(Upstream, 1, OutstandingUpstreams0),
    State1 = State#state{outstanding_upstreams=OutstandingUpstreams},
    case OutstandingUpstreams of
        [] ->
            %% We're done. Great.
            {stop, normal, State1};
        _ ->
            Timeout = erlang:convert_time_unit(Now - State#state.send_query_time, native, milli_seconds),
            {next_state, waiting_for_rest_replies, State1, Timeout}
    end.

%% @private
reply_success(Data, _State = #state{from = {FromModule, FromKey}}) ->
    FromModule:do_reply(FromKey, Data).

%% @private
reply_fail(_State1 = #state{dns_message = DNSMessage, from = {FromModule, FromKey}}) ->
    Reply =
        DNSMessage#dns_message{
            rc = ?DNS_RCODE_SERVFAIL
        },
    EncodedReply = dns:encode_message(Reply),
    FromModule:do_reply(FromKey, EncodedReply).

%% @private
resolve(Parent, Upstream, State) ->
    try do_resolve(Parent, Upstream, State) of
        _ ->
            ok
    catch
        exit:Exception ->
            lager:warning("Resolver (~p) Process exited: ~p", [Upstream, erlang:get_stacktrace()]),
            %% Reraise the exception
            exit(Exception);
        _:_ ->
            lager:warning("Resolver (~p) Process exited: ~p", [Upstream, erlang:get_stacktrace()]),
            exit(unknown_error)
    end.

do_resolve(Parent, Upstream = {UpstreamIP, UpstreamPort}, #state{data = Data, from = {dcos_dns_udp_server, _}}) ->
    lager:debug("Sending query to Upstream: ~p", [Upstream]),
    {ok, _} = timer:kill_after(?TIMEOUT),
    {ok, Socket} = gen_udp:open(0, [{reuseaddr, true}, {active, once}, binary]),
    link(Socket),
    gen_udp:send(Socket, UpstreamIP, UpstreamPort, Data),
    %% Should put a timeout here given we're linked to our parents?
    receive
        {udp, Socket, UpstreamIP, UpstreamPort, ReplyData} ->
            lager:debug("Received Reply"),
            gen_fsm:send_event(Parent, {upstream_reply, Upstream, ReplyData});
        Else ->
            lager:debug("Received else: ~p, while upstream: ~p", [Else, Upstream])
        after ?TIMEOUT ->
            lager:debug("Timed out waiting for upstream: ~p", [Upstream])
    end,
    gen_udp:close(Socket),
    ok;

%% @private
do_resolve(Parent, Upstream = {UpstreamIP, UpstreamPort}, #state{data = Data, from = {dcos_dns_tcp_handler, _}}) ->
    {ok, _} = timer:kill_after(?TIMEOUT),
    TCPOptions = [{active, once}, binary, {packet, 2}, {send_timeout, 1000}],
    {ok, Socket} = gen_tcp:connect(UpstreamIP, UpstreamPort, TCPOptions, ?TIMEOUT),
    link(Socket),
    ok = gen_tcp:send(Socket, Data),
    %% Should put a timeout here given we're linked to our parents?
    receive
        {tcp, Socket, ReplyData} ->
            gen_fsm:send_event(Parent, {upstream_reply, Upstream, ReplyData})
    after ?TIMEOUT ->
        ok
    end,
    gen_tcp:close(Socket),
    ok.

%% @private
take_upstreams(Upstreams0) when length(Upstreams0) < 2 -> %% 0, 1 or 2 Upstreams
    Upstreams0;
take_upstreams(Upstreams0) ->
    ClassifiedUpstreams = lists:map(fun(Upstream) -> {classify_upstream(Upstream), [Upstream]} end, Upstreams0),
    Buckets0 = lists:foldl(
        fun({Bucket, Upstreams}, BucketedUpstreamAcc) ->
            orddict:append_list(Bucket, Upstreams, BucketedUpstreamAcc)
        end,
        orddict:new(), ClassifiedUpstreams),
    %% This gives us the first two buckets of upstreams
    %% We know there will be at least two Upstreams in it
    {_Buckets, UpstreamBuckets} = lists:unzip(Buckets0),
    case UpstreamBuckets of
        [Bucket0|_] when length(Bucket0) > 2 ->
            choose2(Bucket0);
        [Bucket0, Bucket1|_] ->
            choose2(Bucket0 ++ Bucket1)
    end.

%% @private
choose2(List) ->
    Length = length(List),
    case Length > 2 of
        true ->
            %% This could result in querying duplicate upstreams :(
            {Idx0, Idx1} = maybe_two_uniq_rand(Length, 10),
            [lists:nth(Idx0, List), lists:nth(Idx1, List)];
        false ->
            List
    end.

%% @private
maybe_two_uniq_rand(Max, 0) ->
    Rand0 = rand:uniform(Max),
    Rand1 = rand:uniform(Max),
    {Rand0, Rand1};
maybe_two_uniq_rand(Max, MaxTries) ->
    Rand0 = rand:uniform(Max),
    Rand1 = rand:uniform(Max),
    case Rand0 == Rand1 of
        true ->
            maybe_two_uniq_rand(Max, MaxTries - 1);
        false ->
            {Rand0, Rand1}
    end.


%% @private
-spec(classify_upstream(Upstream :: inet:ip4_address()) -> non_neg_integer()).
classify_upstream(Upstream) ->
    case exometer:get_value([?MODULE, Upstream, failures]) of
        {error, _} -> %% If we've never seen it before, assume it never failed
            0;
        {ok, Metric} ->
            {one, Failures} = lists:keyfind(one, 1, Metric),
            Failures
    end.

%% @private
mark_rest_as_failed(#state{outstanding_upstreams=Upstreams}) ->
    mark_rest_as_failed(Upstreams);
mark_rest_as_failed(Upstreams) ->
    lists:foreach(fun({Upstream, _Pid}) ->
        dcos_dns_metrics:update([?MODULE, Upstream, failures], 1, ?SPIRAL)
                  end, Upstreams).