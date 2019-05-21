-module(dcos_net_utils).

-export([
    complement/2,
    complement_size/1,
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
        [], []).

-spec(complement([A], [B], [A], [B]) -> {[A], [B]}
    when A :: term(), B :: term()).
complement([], ListB, Acc, Bcc) ->
    {Acc, ListB ++ Bcc};
complement(ListA, [], Acc, Bcc) ->
    {ListA ++ Acc, Bcc};
complement(List, List, Acc, Bcc) ->
    {Acc, Bcc};
complement([A|ListA], [A|ListB], Acc, Bcc) ->
    complement(ListA, ListB, Acc, Bcc);
complement([A|_]=ListA, [B|ListB], Acc, Bcc) when A > B ->
    complement(ListA, ListB, Acc, [B|Bcc]);
complement([A|ListA], [B|_]=ListB, Acc, Bcc) when A < B ->
    complement(ListA, ListB, [A|Acc], Bcc).

%% @doc Given {A, B} as a complement, Return size(A) + size(B)
-spec(complement_size({[A], [B]}) -> integer()
    when A :: term(), B :: term()).
complement_size({ListA, ListB}) ->
    length(ListA) + length(ListB).

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
