-module(dcos_dns_handler).

-include("dcos_dns.hrl").
-include_lib("dns/include/dns_records.hrl").

-define(TIMEOUT, 5000).

%% API
-export([
    start/3,
    resolve/3,
    init_metrics/0
]).

%% Private functions
-export([start_link/4, init/5]).

-export_type([reply_fun/0, protocol/0]).

-type reply_fun() :: fun ((binary()) -> ok | {error, term()})
                   | {fun ((...) -> ok | {error, term()}), [term()]}
                   | skip.
-type protocol() :: udp | tcp.

-spec(start(protocol(), binary(), reply_fun()) ->
    {ok, pid()} | {error, term()}).
start(Protocol, Request, Fun) ->
    Begin = erlang:monotonic_time(),
    Args = [Begin, Protocol, Request, Fun],
    case sidejob_supervisor:start_child(dcos_dns_handler_sj,
                                        ?MODULE, start_link, Args) of
        {error, Error} ->
            lager:error("Unexpected error: ~p", [Error]),
            {error, Error};
        {ok, Pid} ->
            {ok, Pid}
    end.

-spec(resolve(protocol(), binary(), timeout()) ->
    {ok, binary()} | {error, atom()}).
resolve(Protocol, Request, Timeout) ->
    Ref = make_ref(),
    Fun = {fun resolve_reply_fun/3, [self(), Ref]},
    case dcos_dns_handler:start(Protocol, Request, Fun) of
        {ok, Pid} ->
            MonRef = erlang:monitor(process, Pid),
            receive
                {reply, Ref, Response} ->
                    erlang:demonitor(MonRef, [flush]),
                    {ok, Response};
                {'DOWN', MonRef, process, _Pid, Reason} ->
                   {error, Reason}
            after Timeout ->
                {error, timeout}
            end;
        {error, Error} ->
            {error, Error}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_link(Begin, protocol(), Request, reply_fun()) -> {ok, pid()}
    when Begin :: integer(), Request :: binary()).
start_link(Begin, Protocol, Request, Fun) ->
    Args = [Begin, self(), Protocol, Request, Fun],
    proc_lib:start_link(?MODULE, init, Args).

-spec(init(Begin, pid(), protocol(), Request, reply_fun()) -> ok
    when Begin :: integer(), Request :: binary()).
init(Begin, Parent, Protocol, Request, Fun) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    DNSMessage = #dns_message{} = dns:decode_message(Request),
    Questions = DNSMessage#dns_message.questions,
    case dcos_dns_router:upstreams_from_questions(Questions) of
        {[], Zone} ->
            report_status([?APP, no_upstreams_available]),
            Response = failed_msg(Protocol, DNSMessage),
            ok = reply(Begin, Fun, Response, Zone),
            prometheus_counter:inc(dns, forwarder_failures_total, [Zone], 1);
        {internal, Zone} ->
            Response = internal_resolve(Protocol, DNSMessage),
            ok = reply(Begin, Fun, Response, Zone);
        {Upstreams, Zone} ->
            FailMsg = failed_msg(Protocol, DNSMessage),
            Upstreams0 = take_upstreams(Upstreams),
            resolve(Begin, Protocol, Upstreams0, Request, Fun, FailMsg, Zone)
    end.

-spec(reply(integer(), reply_fun(), binary(), binary()) ->
    ok | {error, term()}).
reply(_Begin, skip, _Response, _Zone) ->
    ok;
reply(Begin, {Fun, Args}, Response, Zone) ->
    try
        apply(Fun, Args ++ [Response])
    after
        prometheus_histogram:observe(
            dns,
            forwarder_requests_duration_seconds,
            [Zone], erlang:monotonic_time() - Begin)
    end;
reply(Begin, Fun, Response, Zone) ->
    reply(Begin, {Fun, []}, Response, Zone).


-spec(resolve_reply_fun(pid(), reference(), binary()) -> ok).
resolve_reply_fun(Pid, Ref, Response) ->
    Pid ! {reply, Ref, Response},
    ok.

-spec(report_status([term()]) -> ok).
report_status(Metric) ->
    dcos_dns_metrics:update(Metric, 1, ?SPIRAL).

%%%===================================================================
%%% Resolvers
%%%===================================================================

-define(LOCALHOST, {127, 0, 0, 1}).

-spec(internal_resolve(protocol(), dns:message()) -> binary()).
internal_resolve(Protocol, DNSMessage) ->
    Response = erldns_handler:do_handle(DNSMessage, ?LOCALHOST),
    encode_message(Protocol, Response).

-spec(resolve(Begin, Protocol, Upstreams, Request, Fun, FailMsg, Zone) -> ok
    when Begin :: integer(),
         Protocol :: protocol(), Upstreams :: [upstream()],
         Request :: binary(), Fun :: reply_fun(),
         FailMsg :: binary(), Zone :: binary()).
resolve(Begin, Protocol, Upstreams, Request, Fun, FailMsg, Zone) ->
    Workers =
        lists:map(fun (Upstream) ->
            Pid = start_worker(Protocol, Upstream, Request),
            MonRef = monitor(process, Pid),
            {Upstream, Pid, MonRef}
        end, Upstreams),
    resolve_loop(Begin, Workers, Fun, FailMsg, Zone).

-spec(resolve_loop(Begin, Workers, Fun, FailMsg, Zone) -> ok
    when Begin :: integer(), Workers :: [{upstream(), pid(), reference()}],
         Fun :: reply_fun(), FailMsg :: binary(), Zone :: binary()).
resolve_loop(_Begin, [], skip, _FailMsg, _Zone) ->
    ok;
resolve_loop(Begin, [], Fun, FailMsg, Zone) ->
    prometheus_counter:inc(dns, forwarder_failures_total, [Zone], 1),
    ok = reply(Begin, Fun, FailMsg, Zone);
resolve_loop(Begin, Workers, Fun, FailMsg, Zone) ->
    receive
        {reply, Pid, Response} ->
            {value, {Upstream, Pid, MonRef}, Workers0} =
                lists:keytake(Pid, 2, Workers),
            _ = reply(Begin, Fun, Response, Zone),
            erlang:demonitor(MonRef, [flush]),
            report_status([?MODULE, Upstream, successes]),
            resolve_loop(Begin, Workers0, skip, FailMsg, Zone);
        {'DOWN', MonRef, process, Pid, _Reason} ->
            {value, {Upstream, Pid, MonRef}, Workers0} =
                lists:keytake(Pid, 2, Workers),
            report_status([?MODULE, Upstream, failures]),
            resolve_loop(Begin, Workers0, Fun, FailMsg, Zone)
    after 2 * ?TIMEOUT ->
        lists:foreach(fun ({Upstream, Pid, MonRef}) ->
            erlang:demonitor(MonRef, [flush]),
            report_status([?MODULE, Upstream, failures]),
            Pid ! {timeout, self()}
        end, Workers),
        resolve_loop(Begin, [], Fun, FailMsg, Zone)
    end.

%%%===================================================================
%%% Workers
%%%===================================================================

-spec(start_worker(protocol(), upstream(), binary()) -> pid()).
start_worker(Protocol, Upstream, Request) ->
    Pid = self(),
    proc_lib:spawn(fun () ->
        init_worker(Protocol, Pid, Upstream, Request)
    end).

-spec(init_worker(protocol(), pid(), upstream(), binary()) -> ok).
init_worker(udp, Pid, Upstreams, Request) ->
    udp_worker(Pid, Upstreams, Request);
init_worker(tcp, Pid, Upstreams, Request) ->
    tcp_worker(Pid, Upstreams, Request).

-spec(udp_worker(pid(), upstream(), binary()) -> ok).
udp_worker(Pid, Upstream = {IP, Port}, Request) ->
    StartTime = erlang:monotonic_time(millisecond),
    Opts = [{reuseaddr, true}, {active, once}, binary],
    case gen_udp:open(0, Opts) of
        {ok, Socket} ->
            case gen_udp:send(Socket, IP, Port, Request) of
                ok ->
                    udp_worker(StartTime, Pid, Socket, Upstream);
                {error, Error} ->
                    lager:warning("DNS worker ~p failed with ~p", [Upstream, Error])
            end;
        {error, Error} ->
            lager:warning("DNS worker ~p failed with ~p", [Upstream, Error])
    end.

-spec(udp_worker(integer(), pid(), gen_udp:socket(), upstream()) -> ok).
udp_worker(StartTime, Pid, Socket, Upstream = {IP, Port}) ->
    MonRef = erlang:monitor(process, Pid),
    try
        receive
            {'DOWN', MonRef, process, _Pid, normal} ->
                ok;
            {'DOWN', MonRef, process, _Pid, Reason} ->
                exit(Reason);
            {udp, Socket, IP, Port, Response} ->
                Pid ! {reply, self(), Response},
                report_latency([?MODULE, Upstream, latency], StartTime);
            {timeout, Pid} ->
                lager:warning("DNS worker ~p timed out", [Upstream])
        after ?TIMEOUT ->
            ok
        end
    after
        gen_udp:close(Socket)
    end.

-spec(tcp_worker(pid(), upstream(), binary()) -> ok).
tcp_worker(Pid, Upstream = {IP, Port}, Request) ->
    StartTime = erlang:monotonic_time(millisecond),
    Opts = [{active, once}, binary, {packet, 2}, {send_timeout, ?TIMEOUT}],
    case gen_tcp:connect(IP, Port, Opts, ?TIMEOUT) of
        {ok, Socket} ->
            case gen_tcp:send(Socket, Request) of
                ok ->
                    tcp_worker(StartTime, Pid, Socket, Upstream);
                {error, Error} ->
                    lager:warning("DNS worker [tcp] ~p failed with ~p", [Upstream, Error])
            end;
        {error, Error} ->
            lager:warning("DNS worker [tcp] ~p failed with ~p", [Upstream, Error])
    end.

-spec(tcp_worker(integer(), pid(), gen_tcp:socket(), upstream()) -> ok).
tcp_worker(StartTime, Pid, Socket, Upstream) ->
    MonRef = erlang:monitor(process, Pid),
    try
        Timeout = ?TIMEOUT - (erlang:monotonic_time(millisecond) - StartTime),
        receive
            {'DOWN', MonRef, process, _Pid, normal} ->
                ok;
            {'DOWN', MonRef, process, _Pid, Reason} ->
                exit(Reason);
            {tcp, Socket, Response} ->
                Pid ! {reply, self(), Response},
                report_latency([?MODULE, Upstream, latency], StartTime);
            {tcp_closed, Socket} ->
                lager:warning("DNS worker [tcp] ~p failed with ~p", [Upstream, closed]);
            {tcp_error, Socket, Reason} ->
                lager:warning("DNS worker [tcp] ~p failed with ~p", [Upstream, Reason]);
            {timeout, Pid} ->
                lager:warning("DNS worker [tcp] ~p timed out", [Upstream])
        after Timeout ->
            ok
        end
    after
        gen_tcp:close(Socket)
    end.

-spec(report_latency([term()], pos_integer()) -> ok).
report_latency(Metric, StartTime) ->
    Diff = max(erlang:monotonic_time(millisecond) - StartTime, 0),
    dcos_dns_metrics:update(Metric, Diff, ?HISTOGRAM).

%%%===================================================================
%%% Upstreams functions
%%%===================================================================

-spec(take_upstreams([upstream()]) -> [upstream()]).
take_upstreams(Upstreams) when length(Upstreams) < 3 ->
    Upstreams;
take_upstreams(Upstreams) ->
    ClassifiedUpstreams =
        lists:map(fun (Upstream) ->
            {upstream_failures(Upstream), Upstream}
        end, Upstreams),
    Buckets = lists:foldl(
        fun({N, Upstream}, Acc) ->
            orddict:append_list(N, [Upstream], Acc)
        end,
        orddict:new(), ClassifiedUpstreams),
    case lists:unzip(Buckets) of
        {_N, [[_, _ | _] = Bucket | _Buckets]} ->
            choose(2, Bucket);
        {_N, [[Upstream], Bucket | _Buckets]} ->
            [Upstream | choose(1, Bucket)]
    end.

-spec(choose(N :: pos_integer(), [T]) -> [T] when T :: any()).
choose(1, [Element]) ->
    [Element];
choose(N, List) ->
    % Shuffle list and take N first elements
    List0 = [{rand:uniform(), X} || X <- List],
    List1 = lists:sort(List0),
    List2 = [X || {_, X} <- List1],
    lists:sublist(List2, N).

-spec(upstream_failures([upstream()]) -> non_neg_integer()).
upstream_failures(Upstream) ->
    case exometer:get_value([?MODULE, Upstream, failures]) of
        {error, _Error} ->
            0;
        {ok, Metric} ->
            {one, Failures} = lists:keyfind(one, 1, Metric),
            Failures
    end.

%%%===================================================================
%%% DNS functions
%%%===================================================================

-spec failed_msg(protocol(), dns:message()) -> binary().
failed_msg(Protocol, DNSMessage) ->
    Reply =
        DNSMessage#dns_message{
            rc = ?DNS_RCODE_SERVFAIL
        },
    encode_message(Protocol, Reply).

-spec encode_message(protocol(), dns:message()) -> binary().
encode_message(Protocol, DNSMessage) ->
    Opts = encode_message_opts(Protocol, DNSMessage),
    case erldns_encoder:encode_message(DNSMessage, Opts) of
        {false, EncodedMessage} ->
            EncodedMessage;
        {true, EncodedMessage, #dns_message{}} ->
            EncodedMessage;
        {false, EncodedMessage, _TsigMac} ->
            EncodedMessage;
        {true, EncodedMessage, _TsigMac, _Message} ->
            EncodedMessage
    end.

-spec encode_message_opts(protocol(), dns:message()) ->
    [dns:encode_message_opt()].
encode_message_opts(tcp, _DNSMessage) ->
    [];
encode_message_opts(udp, DNSMessage) ->
    [{max_size, max_payload_size(DNSMessage)}].

-define(MAX_PACKET_SIZE, 512).

%% Determine the max payload size by looking for additional
%% options passed by the client.
-spec max_payload_size(dns:message()) -> pos_integer().
max_payload_size(
        #dns_message{additional =
            [#dns_optrr{udp_payload_size = PayloadSize}
            |_Additional]})
        when is_integer(PayloadSize) ->
    PayloadSize;
max_payload_size(_DNSMessage) ->
    ?MAX_PACKET_SIZE.

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(init_metrics() -> ok).
init_metrics() ->
    prometheus_counter:new([
        {registry, dns},
        {name, forwarder_failures_total},
        {labels, [zone]},
        {help, "Total number of DNS request failures."}]),
    prometheus_histogram:new([
        {registry, dns},
        {name, forwarder_requests_duration_seconds},
        {labels, [zone]},
        {duration_unit, seconds},
        {buckets, [0.001, 0.005, 0.010, 0.050, 0.100, 0.500, 1.000, 5.000]},
        {help, "The time spent processing DNS requests."}]),
    prometheus_counter:new([
        {registry, dns},
        {name, forwarder_worker_failures_total},
        {labels, [zone, protocol]},
        {help, "Total number of worker failures processing DNS requests."}]),
    prometheus_histogram:new([
        {registry, dns},
        {name, forwarder_worker_requests_duration_seconds},
        {labels, [zone, protocol]},
        {duration_unit, seconds},
        {buckets, [0.001, 0.005, 0.010, 0.050, 0.100, 0.500, 1.000, 5.000]},
        {help, "The time spent a worker spent processing DNS requests."}]).
