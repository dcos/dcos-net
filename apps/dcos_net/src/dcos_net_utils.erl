-module(dcos_net_utils).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    system/1,
    system/2
]).

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
