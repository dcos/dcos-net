-module(dcos_dns_metrics).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

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
    exometer:new([dcos_dns_udp_server, successes], ?COUNTER),
    exometer:new([dcos_dns_udp_server, failures], ?COUNTER),

    %% Successes and failures for the TCP server.
    exometer:new([dcos_dns_tcp_handler, successes], ?COUNTER),
    exometer:new([dcos_dns_tcp_handler, failures], ?COUNTER),

    %% Number of queries received where we've answered only one of
    %% multiple questions presented.
    exometer:new([dcos_dns, ignored_questions], ?COUNTER),

    %% No upstreams responded.
    exometer:new([dcos_dns, upstreams_failed], ?COUNTER),

    %% No upstreams available.
    exometer:new([dcos_dns, no_upstreams_available], ?COUNTER).
