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

%%====================================================================
%% Dist functions
%%====================================================================

listen(Name) ->
    set_dist_port(Name),
    M = dist_module(),
    M:listen(Name).

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
    {ok, Port} = dcos_net_app:dist_port(),
    ok = application:set_env(kernel, inet_dist_listen_min, Port),
    ok = application:set_env(kernel, inet_dist_listen_max, Port);
set_dist_port(_Name) ->
    ok.

dist_module() ->
    case init:get_argument(ssl_dist_optfile) of
        {ok, [_SSLDistOptFiles]} ->
            inet_tls_dist;
        error ->
            inet_tcp_dist
    end.

ssl_dist_opts(SSLDistOptFile) ->
    try
        ets:tab2list(ssl_dist_opts)
    catch error:badarg ->
        ssl_dist_sup:consult(SSLDistOptFile)
    end.
