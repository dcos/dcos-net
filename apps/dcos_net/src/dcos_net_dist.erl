-module(dcos_net_dist).

-export([
    hostname/0,
    nodeip/0,
    listen/1,
    select/1,
    accept/1,
    accept_connection/5,
    setup/5,
    close/1,
    childspecs/0
]).

-spec(hostname() -> binary()).
hostname() ->
    [_Name, Hostname] = binary:split(atom_to_binary(node(), latin1), <<"@">>),
    Hostname.

-spec(nodeip() -> inet:ip4_address()).
nodeip() ->
    Hostname = hostname(),
    Hostname0 = binary_to_list(Hostname),
    case inet:parse_ipv4strict_address(Hostname0) of
        {ok, IP} -> IP;
        {error, _} -> {0, 0, 0, 0}
    end.

listen(Name) ->
    set_dist_port(Name),
    M = dist_module(),
    try M:listen(Name) of
        {ok, Result} ->
            {ok, Result};
        Other ->
            critical_error("[~p] ~p", [Name, Other])
    catch C:E ->
        critical_error("[~p] ~p:~p", [Name, C, E])
    end.

select(Node) ->
    M = dist_module(),
    M:select(Node).

accept(Listen) ->
    M = dist_module(),
    M:accept(Listen).

accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    M = dist_module(),
    M:accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime).

setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    M = dist_module(),
    M:setup(Node, Type, MyNode, LongOrShortNames, SetupTime).

close(Listen) ->
    M = dist_module(),
    M:close(Listen).

childspecs() ->
    M = dist_module(),
    M:childspecs().

%%====================================================================
%% Internal functions
%%====================================================================

set_dist_port(navstar) ->
    case dcos_net_app:dist_port() of
        {ok, Port} ->
            ok = application:set_env(kernel, inet_dist_listen_min, Port),
            ok = application:set_env(kernel, inet_dist_listen_max, Port);
        {error, Error} ->
            critical_error("Couldn't find dist port: ~p", [Error])
    end;
set_dist_port(_Name) ->
    ok.

dist_module() ->
    case init:get_argument(ssl_dist_opt) of
        {ok, Args} ->
            Args0 = lists:map(fun list_to_tuple/1, Args),
            check_ssl_dist_opt(Args0),
            inet_tls_dist;
        error ->
            inet_tcp_dist
    end.

check_ssl_dist_opt(Args) ->
    check_ssl_dist_opt([
        {"client_cacertfile", file},
        {"client_keyfile", file},
        {"client_certfile", file},
        {"client_verify", verify},
        {"client_depth", integer},
        {"server_cacertfile", file},
        {"server_keyfile", file},
        {"server_certfile", file},
        {"server_verify", verify},
        {"server_fail_if_no_peer_cert", true},
        {"server_depth", integer}
    ], Args).

check_ssl_dist_opt([], _Args) ->
    ok;
check_ssl_dist_opt([{Key, Type}|Opts], Args) ->
    case lists:keyfind(Key, 1, Args) of
        {Key, Value} ->
            check_ssl_dist_opt(Key, Value, Type);
        _ ->
            critical_error("Couldn't find ssl_dist_opt ~s", [Key])
    end,
    check_ssl_dist_opt(Opts, Args).

check_ssl_dist_opt(Key, Value, file) ->
    case filelib:is_file(Value, erl_prim_loader) of
        true ->
            ok;
        false ->
            critical_error("~s (~s) doesn't exist", [Value, Key])
    end;
check_ssl_dist_opt(Key, Value, integer) ->
    try list_to_integer(Value) of
        _Value ->
            ok
    catch error:badarg ->
        critical_error("~s (~s) is not an integer", [Value, Key])
    end;
check_ssl_dist_opt(Key, Value, verify) ->
    case Value of
        "verify_peer" ->
            ok;
        Value ->
            critical_error("~s (~s) is not verify_peer", [Value, Key])
    end;
check_ssl_dist_opt(Key, Value, true) ->
    case Value of
        "true" ->
            ok;
        Value ->
            critical_error("~s (~s) is not true", [Value, Key])
    end.

critical_error(Format, Args) ->
    io:format(standard_error, "~p: ", [?MODULE]),
    io:format(standard_error, Format, Args),
    io:format(standard_error, "~n", []),
    erlang:halt(1).
