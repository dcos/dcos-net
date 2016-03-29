-module(dcos_dns_metrics).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").
-author("Sargun Dhillon <sargun@mesosphere.com").

-export([update/3,
         setup/0]).

-include("dcos_dns.hrl").

%% @doc Bump a metric.
update(Metric, Value, Type) ->
    case exometer:update(Metric, Value) of
        {error, not_found} ->
            ok = exometer:ensure(Metric, Type, []),
            ok = exometer:update(Metric, Value);
        _ ->
            ok
    end.

%% @doc Configure all metrics.
setup() ->
    %% Successes and failures for the UDP server.
    ok = exometer:ensure([dcos_dns_udp_server, successes], ?COUNTER, []),
    ok = exometer:ensure([dcos_dns_udp_server, failures], ?COUNTER, []),

    %% Successes and failures for the TCP server.
    ok = exometer:ensure([dcos_dns_tcp_handler, successes], ?COUNTER, []),
    ok = exometer:ensure([dcos_dns_tcp_handler, failures], ?COUNTER, []),

    %% Number of queries received where we've answered only one of
    %% multiple questions presented.
    ok = exometer:ensure([dcos_dns, ignored_questions], ?COUNTER, []),

    %% No upstreams responded.
    ok = exometer:ensure([dcos_dns, upstreams_failed], ?COUNTER, []),

    %% No upstreams available.
    ok = exometer:ensure([dcos_dns, no_upstreams_available], ?COUNTER, []).
