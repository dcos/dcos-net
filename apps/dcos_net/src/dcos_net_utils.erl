-module(dcos_net_utils).

-export([
    complement/2,
    system/1,
    system/2,
    join/2
]).

%%%===================================================================
%%% Complement functions
%%%===================================================================

%% @doc Return {A\B, B\A}
-spec(complement([A], [B]) -> {[A], [B]}
    when A :: term(), B :: term()).
complement(ListA, ListB) ->
    complement(
        lists:sort(ListA),
        lists:sort(ListB),
        [], [], 0).

-spec(complement([A], [B], [A], [B], R) -> {[A], [B]}
    when A :: term(), B :: term(), R :: non_neg_integer()).
complement(ListA, ListB, Acc, Bcc, R) when R > 10000 ->
    % NOTE: VM doesn't increment reductions in the complement function.
    % Sysmon shows that on huge lists it regurarly blocks schedulers.
    % We have to increment recuctions manually to force a context switch.
    erlang:bump_reductions(1000),
    complement(ListA, ListB, Acc, Bcc, 0);
complement([], ListB, Acc, Bcc, _R) ->
    {Acc, ListB ++ Bcc};
complement(ListA, [], Acc, Bcc, _R) ->
    {ListA ++ Acc, Bcc};
complement(List, List, Acc, Bcc, _R) ->
    {Acc, Bcc};
complement([A|ListA], [A|ListB], Acc, Bcc, R) ->
    complement(ListA, ListB, Acc, Bcc, R + 1);
complement([A|_]=ListA, [B|ListB], Acc, Bcc, R) when A > B ->
    complement(ListA, ListB, Acc, [B|Bcc], R + 1);
complement([A|ListA], [B|_]=ListB, Acc, Bcc, R) when A < B ->
    complement(ListA, ListB, [A|Acc], Bcc, R + 1).

%%%===================================================================
%%% System functions
%%%===================================================================

-spec(system([binary()]) ->
    {ok, binary()} | {error, atom() | {exit_status, non_neg_integer()}}).
system(Command) ->
    system(Command, 5000).

-spec(system([binary()], non_neg_integer()) ->
    {ok, binary()} | {error, atom() | {exit_status, non_neg_integer()}}).
system([Command|Args], Timeout) ->
    Opts = [exit_status, binary, {args, Args}],
    EndTime = erlang:monotonic_time(millisecond) + Timeout,
    try erlang:open_port({spawn_executable, Command}, Opts) of
        Port ->
            system_loop(Port, EndTime, <<>>)
    catch error:Error ->
        {error, Error}
    end.

-spec(system_loop(port(), integer(), binary()) ->
    {ok, binary()} | {error, atom() | {exit_status, non_neg_integer()}}).
system_loop(Port, EndTime, Acc) ->
    Timeout = EndTime - erlang:monotonic_time(millisecond),
    receive
        {Port, {data, Data}} ->
            system_loop(Port, EndTime, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, ExitCode}} ->
            {error, {exit_status, ExitCode}}
    after Timeout ->
        erlang:port_close(Port),
        {error, timeout}
    end.

%%%===================================================================
%%% Binary functions
%%%===================================================================

-spec(join([binary()], binary()) -> binary()).
join([], _Sep) ->
    <<>>;
join(List, Sep) ->
    SepSize = size(Sep),
    <<Sep:SepSize/binary, Result/binary>> =
        << <<Sep/binary, X/binary>> || X <- List >>,
    Result.
