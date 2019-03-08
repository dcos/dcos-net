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
            {value, {_Upstream, Pid, MonRef}, Workers0} =
                lists:keytake(Pid, 2, Workers),
            _ = reply(Begin, Fun, Response, Zone),
            erlang:demonitor(MonRef, [flush]),
            resolve_loop(Begin, Workers0, skip, FailMsg, Zone);
        {'DOWN', MonRef, process, Pid, _Reason} ->
            {value, {_Upstream, Pid, MonRef}, Workers0} =
                lists:keytake(Pid, 2, Workers),
            resolve_loop(Begin, Workers0, Fun, FailMsg, Zone)
    after 2 * ?TIMEOUT ->
        lists:foreach(fun ({_Upstream, Pid, MonRef}) ->
            erlang:demonitor(MonRef, [flush]),
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
    Begin = erlang:monotonic_time(),
    proc_lib:spawn(fun () ->
        Address = upstream_to_binary(Upstream),
        init_worker(Protocol, Pid, {Upstream, Address}, Request),
        prometheus_histogram:observe(
            dns, worker_requests_duration_seconds,
            [Address, udp], erlang:monotonic_time() - Begin)
    end).

-spec(init_worker(protocol(), pid(), {upstream(), binary()}, binary()) -> ok).
init_worker(udp, Pid, Upstream, Request) ->
    udp_worker(Pid, Upstream, Request);
init_worker(tcp, Pid, Upstream, Request) ->
    tcp_worker(Pid, Upstream, Request).

-spec(udp_worker(pid(), {upstream(), binary()}, binary()) -> ok).
udp_worker(Pid, {Upstream = {IP, Port}, Address}, Request) ->
    Opts = [{reuseaddr, true}, {active, once}, binary],
    case gen_udp:open(0, Opts) of
        {ok, Socket} ->
            case gen_udp:send(Socket, IP, Port, Request) of
                ok ->
                    udp_worker_receive(Pid, Socket, {Upstream, Address});
                {error, Reason} ->
                    lager:warning(
                        "DNS worker ~p failed with ~p",
                        [Address, Reason]),
                    emit_worker_failure(Address, udp, Reason)
            end;
        {error, Reason} ->
            lager:warning("DNS worker ~p failed with ~p", [Address, Reason]),
            emit_worker_failure(Address, udp, Reason)
    end.

-spec(udp_worker_receive(pid(), gen_udp:socket(), {upstream(), binary()}) -> ok).
udp_worker_receive(Pid, Socket, {{IP, Port}, Address}) ->
    MonRef = erlang:monitor(process, Pid),
    try
        receive
            {'DOWN', MonRef, process, _Pid, normal} ->
                ok;
            {'DOWN', MonRef, process, _Pid, Reason} ->
                emit_worker_failure(Address, udp, Reason),
                exit(Reason);
            {udp, Socket, IP, Port, Response} ->
                Pid ! {reply, self(), Response};
            {timeout, Pid} ->
                lager:warning("DNS worker ~p timed out", [Address])
        after ?TIMEOUT ->
            emit_worker_failure(Address, udp, timeout),
            ok
        end
    after
        gen_udp:close(Socket)
    end.

-spec(tcp_worker(pid(), {upstream(), binary()}, binary()) -> ok).
tcp_worker(Pid, { Upstream = {IP, Port}, Address}, Request) ->
    StartTime = erlang:monotonic_time(millisecond),
    Opts = [{active, once}, binary, {packet, 2}, {send_timeout, ?TIMEOUT}],
    case gen_tcp:connect(IP, Port, Opts, ?TIMEOUT) of
        {ok, Socket} ->
            case gen_tcp:send(Socket, Request) of
                ok ->
                    tcp_worker_receive(StartTime, Pid, Socket, {Upstream, Address});
                {error, Reason} ->
                    lager:warning("DNS worker [tcp] ~p failed with ~p", [Address, Reason]),
                    emit_worker_failure(Address, tcp, Reason)
            end;
        {error, Reason} ->
            lager:warning("DNS worker [tcp] ~p failed with ~p", [Address, Reason]),
            emit_worker_failure(Address, tcp, Reason)
    end.

-spec(tcp_worker_receive(integer(), pid(), gen_tcp:socket(), {upstream(), binary()}) -> ok).
tcp_worker_receive(StartTime, Pid, Socket, {_Upstream, Address}) ->
    MonRef = erlang:monitor(process, Pid),
    try
        Timeout = ?TIMEOUT - (erlang:monotonic_time(millisecond) - StartTime),
        receive
            {'DOWN', MonRef, process, _Pid, normal} ->
                ok;
            {'DOWN', MonRef, process, _Pid, Reason} ->
                emit_worker_failure(Address, tcp, Reason),
                exit(Reason);
            {tcp, Socket, Response} ->
                Pid ! {reply, self(), Response};
            {tcp_closed, Socket} ->
                lager:warning("DNS worker [tcp] ~p failed with ~p", [Address, closed]),
                emit_worker_failure(Address, tcp, tcp_closed);
            {tcp_error, Socket, Reason} ->
                lager:warning("DNS worker [tcp] ~p failed with ~p", [Address, Reason]),
                emit_worker_failure(Address, tcp, tcp_error);
            {timeout, Pid} ->
                lager:warning("DNS worker [tcp] ~p timed out", [Address]),
                emit_worker_failure(Address, tcp, tcp_timeout)
        after Timeout ->
            emit_worker_failure(Address, tcp, timeout),
            ok
        end
    after
        gen_tcp:close(Socket)
    end.

%%===================================================================
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

-spec(upstream_failures(upstream()) -> number()).
upstream_failures(Upstream) ->
    UpstreamAddress = upstream_to_binary(Upstream),
    AllFailures = prometheus_counter:values(dns, worker_failures_total),
    ChooseMap = fun({[{"upstream_address", Ul} | _], V}) ->
       case Ul =:= UpstreamAddress of
           true -> {true, V};
           _ -> false
       end
    end,
    UpstreamFailures = lists:filtermap(ChooseMap, AllFailures),
    lists:sum(UpstreamFailures).

-spec(upstream_to_binary(upstream()) -> binary()).
upstream_to_binary({Ip, Port}) ->
    IpBin = list_to_binary(inet:ntoa(Ip)),
    PortBin = integer_to_binary(Port),
    <<IpBin/binary, ":", PortBin/binary>>.

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
        {name, worker_failures_total},
        {labels, [upstream_address, protocol, reason]},
        {help, "Total number of worker failures processing DNS requests."}]),
    prometheus_histogram:new([
        {registry, dns},
        {name, worker_requests_duration_seconds},
        {labels, [upstream_address, protocol]},
        {duration_unit, seconds},
        {buckets, [0.001, 0.005, 0.010, 0.050, 0.100, 0.500, 1.000, 5.000]},
        {help, "The time a worker spent processing DNS requests."}]).

-spec(emit_worker_failure(binary(), udp | tcp, atom()) -> ok).
emit_worker_failure(Address, Protocol, Reason) ->
    prometheus_counter:inc(
        dns, worker_failures_total,
        [Address, Protocol, Reason], 1).
