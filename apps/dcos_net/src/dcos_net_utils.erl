-module(dcos_net_utils).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    complement/2
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
