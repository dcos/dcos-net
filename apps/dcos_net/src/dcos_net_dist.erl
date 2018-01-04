-module(dcos_net_dist).

-export([
    hostname/0,
    nodeip/0,
    ssl_dist_opts/0
]).

% dist callbacks
-export([
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

-ifdef(TEST).
-define(NOIP, {0, 0, 0, 0}).
-else.
-define(NOIP, error(noip)).
-endif.

-spec(nodeip() -> inet:ip4_address()).
nodeip() ->
    Hostname = hostname(),
    Hostname0 = binary_to_list(Hostname),
    case inet:parse_ipv4strict_address(Hostname0) of
        {ok, IP} -> IP;
        {error, _} -> ?NOIP
    end.

-spec(ssl_dist_opts() -> [{server | client, ssl:ssl_option()}] | false).
ssl_dist_opts() ->
    case init:get_argument(ssl_dist_optfile) of
        {ok, [[SSLDistOptFile]]} ->
            ssl_dist_opts(SSLDistOptFile);
        error ->
            false
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
            critical_error("Couldn't find dist port [~p]", [Error])
    end;
set_dist_port(_Name) ->
    ok.

dist_module() ->
    case init:get_argument(ssl_dist_optfile) of
        {ok, [[SSLDistOptFile]]} ->
            try ssl_dist_opts(SSLDistOptFile) of
                DistOpts ->
                    lists:foreach(fun check_ssl_dist_opt/1, DistOpts),
                    inet_tls_dist
            catch T:E ->
                critical_error("ssl_dist_opts (~s) [~p] ~p", [SSLDistOptFile, T, E])
            end;
        error ->
            inet_tcp_dist
    end.

ssl_dist_opts(SSLDistOptFile) ->
    try
        ets:tab2list(ssl_dist_opts)
    catch error:badarg ->
        ssl_dist_sup:consult(SSLDistOptFile)
    end.

check_ssl_dist_opt({Type, Opts}) ->
    Checks = #{
        verify => fun is_verify_peer/1,
        secure_renegotiate => fun is_true/1,
        fail_if_no_peer_cert => fun is_true/1,
        certfile => fun is_file/1,
        keyfile => fun is_file/1,
        cacertfile => fun is_file/1,
        depth => fun is_integer/1
    },
    lists:foreach(fun ({Key, Value}) ->
        Fun = maps:get(Key, Checks, fun is_unexpected/1),
        case Fun(Value) of
            false ->
                critical_error(
                    "Unexpected value [~p ~p] ~p",
                    [Type, Key, Value]);
            true -> ok
        end
    end, Opts).

is_file(File) ->
    filelib:is_file(File, erl_prim_loader).

is_verify_peer(Value) ->
     Value =:= verify_peer.

is_true(Value) ->
    Value =:= true.

is_unexpected(_Value) ->
    false.

critical_error(Format, Args) ->
    io:format(standard_error, "~p: ", [?MODULE]),
    io:format(standard_error, Format, Args),
    io:format(standard_error, "~n", []),
    erlang:halt(1).
