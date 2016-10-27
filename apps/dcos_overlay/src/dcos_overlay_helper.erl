%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------
-module(dcos_overlay_helper).

%% Application callbacks
-export([run_command/1, run_command/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

run_command(Command, Opts) ->
    Cmd = lists:flatten(io_lib:format(Command, Opts)),
    run_command(Cmd).

-spec(run_command(Command :: string()) ->
    {ok, Output :: string()} | {error, ErrorCode :: non_neg_integer(), ErrorString :: string()}).
-ifdef(DEV).
run_command("ip link show dev vtep1024") ->
    {error, 1, ""};
run_command(Command) ->
    io:format("Would run command: ~p~n", [Command]),
    {ok, ""}.
-else.
run_command(Command) ->
    Port = open_port({spawn, Command}, [stream, in, eof, hide, exit_status, stderr_to_stdout]),
    get_data(Port, []).

get_data(Port, Sofar) ->
    receive
        {Port, {data, []}} ->
            get_data(Port, Sofar);
        {Port, {data, Bytes}} ->
            get_data(Port, [Sofar|Bytes]);
        {Port, eof} ->
            return_data(Port, Sofar)
    end.

return_data(Port, Sofar) ->
    Port ! {self(), close},
    receive
        {Port, closed} ->
            true
    end,
    receive
        {'EXIT',  Port,  _} ->
            ok
    after 1 ->              % force context switch
        ok
    end,
    ExitCode =
        receive
            {Port, {exit_status, Code}} ->
                Code
        end,
    case ExitCode of
        0 ->
            {ok, lists:flatten(Sofar)};
        _ ->
            {error, ExitCode, lists:flatten(Sofar)}
    end.

-endif.

-ifdef(TEST).
run_command_test() ->
    ?assertEqual({error, 1, ""}, run_command("false")),
    ?assertEqual({ok, ""}, run_command("true")).
-endif.
