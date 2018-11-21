-module(dcos_net_utils).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    complement/2,
    system/1,
    system/2
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

-ifdef(TEST).

complement_test() ->
    {A, B} =
        complement(
            [a, 0, b, 1, c, 2],
            [e, 0, d, 1, f, 2]),
    ?assertEqual(
        {[a, b, c], [d, e, f]},
        {lists:sort(A), lists:sort(B)}).

-endif.

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

-ifdef(TEST).

system_test() ->
    case system([<<"/bin/pwd">>]) of
        {error, enoent} -> ok;
        {ok, Pwd} ->
            {ok, Cwd} = file:get_cwd(),
            ?assertEqual(iolist_to_binary([Cwd, "\n"]), Pwd)
    end.

system_timeout_test() ->
    case system([<<"/bin/dd">>], 100) of
        {error, enoent} -> ok;
        {error, timeout} -> ok
    end.

-endif.
