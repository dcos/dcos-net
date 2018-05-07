-module(dcos_net_statsd).
-behaviour(gen_server).

-include_lib("kernel/include/inet.hrl").

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-type metric() :: {iodata(), non_neg_integer() | float()}.

-record(state, {
    tref :: reference()
}).

-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    TRef = start_push_timer(),
    {ok, #state{tref=TRef}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({timeout, TRef0, push},
        #state{tref=TRef0}=State) ->
    push_metrics(),
    TRef = start_push_timer(),
    {noreply, State#state{tref=TRef}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_push_timer() -> reference()).
start_push_timer() ->
    Timeout = application:get_env(dcos_net, metrics_push_timeout, 5000),
    Timeout0 = Timeout - erlang:system_time(millisecond) rem Timeout,
    erlang:start_timer(Timeout0, self(), push).

%%%===================================================================
%%% Metrics functions
%%%===================================================================

-spec(push_metrics() -> ok).
push_metrics() ->
    MetricsInfo = folsom_metrics:get_metrics_info(),
    MetricsInfo0 = filter_metrics(MetricsInfo),
    Metrics = expand_metrics(MetricsInfo0),
    send_metrics(Metrics).

-spec(filter_metrics(MetricsInfo) -> MetricsInfo
    when MetricsInfo :: [{Name :: term(), Opts :: list()}]).
filter_metrics(MetricsInfo) ->
    MetricsPrefixes = application:get_env(
        dcos_net, metrics_prefixes,
        [vm, mesos, dns, overlay, l4lb]),
    [{Name, Opts} || {Name, Opts} <- MetricsInfo, is_tuple(Name),
     lists:member(element(1, Name), MetricsPrefixes)].

-spec(expand_metrics([{Name :: tuple(), Opts :: list()}]) -> [metric()]).
expand_metrics(MetricsInfo) ->
    lists:flatmap(fun expand/1, MetricsInfo).

-spec(expand({Name :: tuple(), Opts :: list()}) -> [metric()]).
expand({Name, Opts}) ->
    Type = proplists:get_value(type, Opts),
    expand(Type, Name).

-spec(expand(Type :: atom(), Name :: tuple()) -> [metric()]).
expand(gauge, Name) ->
    Value = folsom_metrics_gauge:get_value(Name),
    [{to_name(Name), Value}];
expand(counter, Name) ->
    Value = folsom_metrics_counter:get_value(Name),
    [{to_name(Name), Value}];
expand(histogram, Name) ->
    Values = folsom_metrics_histogram:get_values(Name),
    Stats = hist_statistics(Values),
    lists:map(fun ({P, V}) ->
        {to_name(Name, P), V}
    end, Stats).

-spec(to_name(atom() | binary() | non_neg_integer() | tuple()) -> iodata()).
to_name(Atom) when is_atom(Atom) ->
    Bin = atom_to_binary(Atom, latin1),
    binary:replace(Bin, <<".">>, <<"-">>, [global]);
to_name(Bin) when is_binary(Bin) ->
    Bin;
to_name(Num) when is_integer(Num), Num >= 0 ->
    integer_to_binary(Num);
to_name(Tuple) when is_tuple(Tuple) ->
    List = tuple_to_list(Tuple),
    List0 = lists:map(fun to_name/1, List),
    lists:join(".", List0).

-spec(to_name(X, X) -> iodata()
    when X :: atom() | binary() | tuple()).
to_name(Head, Tail) ->
    [to_name(Head), ".", to_name(Tail)].

%%%===================================================================
%%% Statsd functions
%%%===================================================================

-spec(send_metrics([metric()]) -> ok).
send_metrics(Metrics) ->
    Host = application:get_env(dcos_net, statsd_udp_host, undefined),
    Port = application:get_env(dcos_net, statsd_udp_port, undefined),
    send_metrics(Host, Port, Metrics).

-spec(send_metrics(inet:hostname() | undefined,
                   inet:port_number() | undefined,
                   [metric()]) -> ok).
send_metrics(_Host, undefined, _Metrics) ->
    ok;
send_metrics(undefined, _Port, _Metrics) ->
    ok;
send_metrics(Host, Port, Metrics) ->
    {ok, UDPPort} = gen_udp:open(0),
    try
        lists:foreach(fun ({Name, Value}) ->
            % SPEC: https://github.com/b/statsd_spec#gauges
            Data = ["dcos.net.", Name, ":", to_bin(Value), "|g"],
            ok = gen_udp:send(UDPPort, Host, Port, Data)
        end, Metrics)
    after
        gen_udp:close(UDPPort)
    end.

-spec(to_bin(number()) -> binary()).
to_bin(Value) when is_integer(Value) ->
    integer_to_binary(Value);
to_bin(Value) when is_float(Value) ->
    float_to_binary(Value, [{decimals, 2}, compact]).

%%%===================================================================
%%% Histogram functions
%%%===================================================================

-spec(hist_statistics([number()]) -> [{atom(), number()}]).
hist_statistics([]) ->
    [];
hist_statistics(Values) ->
    Size = length(Values),
    Values0 = lists:sort(Values),
    [
        {max, lists:last(Values0)},
        {p99, percentile(Values0, Size, 0.99)},
        {p95, percentile(Values0, Size, 0.95)},
        {p75, percentile(Values0, Size, 0.75)},
        {p50, percentile(Values0, Size, 0.5)},
        {mean, lists:sum(Values0) / Size}
    ].

-spec(percentile([number()], pos_integer(), float()) -> number()).
percentile(Values, Size, Percentile) ->
    Element = round(Percentile * Size),
    lists:nth(Element, Values).
