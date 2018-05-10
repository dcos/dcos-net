-module(dcos_net_statsd_tests).

-include_lib("eunit/include/eunit.hrl").

-export([statsd_init/1]).

statsd_test_() ->
    {setup, fun setup/0, fun cleanup/1, {generator,
        fun () ->
            {with, statsd_metrics(), [
                fun check_prefixes/1,
                fun vm_metrics/1
            ]}
        end
    }}.

%%%===================================================================
%%% Tests
%%%===================================================================

check_prefixes(Metrics) ->
    lists:all(fun ({<<"dcos.net.", _/binary>>, _Value}) -> true end, Metrics).

vm_metrics(Metrics) ->
    Expected = [
        <<"context_switches">>,
        <<"gc.calls">>, <<"gc.words">>,
        <<"io.input">>, <<"io.output">>,
        <<"reductions">>, <<"runtime">>,
        <<"tasks.active">>, <<"tasks.queue">>,
        <<"ports">>, <<"processes">>, <<"nodes">>,
        <<"memory.total">>, <<"memory.processes">>,
        <<"memory.processes_used">>, <<"memory.system">>,
        <<"memory.atom">>, <<"memory.atom_used">>,
        <<"memory.binary">>, <<"memory.code">>, <<"memory.ets">>,
        <<"utilization.total">> |
        [<<"utilization.scheduler.", (integer_to_binary(N))/binary>>
        || N <- lists:seq(1, erlang:system_info(schedulers))]
    ],
    ?assertEqual(
        lists:sort(Expected),
        [Key || {<<"dcos.net.vm.", Key/binary>>, _V} <- lists:sort(Metrics)]).

%%%===================================================================
%%% Setup & Cleanup
%%%===================================================================

setup() ->
    {ok, SPid, Port} = proc_lib:start_link(?MODULE, statsd_init, [self()]),

    error_logger:tty(false),
    ok = application:start(bear),
    ok = application:start(folsom),

    application:load(dcos_net),
    application:set_env(dcos_net, metrics_push_timeout, 1),
    application:set_env(dcos_net, statsd_udp_host, "127.0.0.1"),
    application:set_env(dcos_net, statsd_udp_port, Port),

    {ok, _Pid} = dcos_net_statsd:start_link(),

    timer:sleep(100),

    SPid.

cleanup(SPid) ->
    Pid = whereis(dcos_net_statsd),
    unlink(Pid),
    exit(Pid, kill),

    SPid ! stop,

    ok = application:stop(bear),
    ok = application:unload(bear),
    ok = application:stop(folsom),
    ok = application:unload(folsom).

%%%===================================================================
%%% StatsD UDP Server
%%%===================================================================

-define(LOCALHOST, {127, 0, 0, 1}).

statsd_init(Parent) ->
    ets:new(?MODULE, [named_table, public]),
    {ok, Socket} = gen_udp:open(0, [{ip, ?LOCALHOST}, {active, true}, binary]),
    {ok, Port} = inet:port(Socket),
    proc_lib:init_ack(Parent, {ok, self(), Port}),
    statsd_loop(Socket).

statsd_loop(Socket) ->
    receive
        {udp, Socket, _IP, _Port, Data} ->
            application:unset_env(dcos_net, metrics_push_timeout),
            [Key, Tail] = binary:split(Data, <<":">>),
            [Head, <<"g">>] = binary:split(Tail, <<"|">>),
            Value =
                try
                    binary_to_integer(Head)
                catch error:badarg ->
                    binary_to_float(Head)
                end,
            ets:insert(?MODULE, {Key, Value}),
            statsd_loop(Socket);
        stop ->
            ok
    end.

statsd_metrics() ->
    ets:tab2list(?MODULE).
