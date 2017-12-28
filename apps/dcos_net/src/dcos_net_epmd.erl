-module(dcos_net_epmd).

% EPMD Module
-export([
    register_node/3,
    port_please/2,
    names/1
]).

% EPMD Server
-export([
    start_link/4,
    init/4
]).

-define(DIST_PROTO_VSN, 5).

-spec(names(Host) -> {ok, [{Name, Port}]} | {error, Reason} when
      Host :: atom() | string() | inet:ip_address(), Name :: string(),
      Port :: non_neg_integer(), Reason :: address | file:posix()).
names(_Hostname) ->
    {ok, [{"dcos-net", port()}, {"navstar", port()}]}.

-spec(register_node(Name, Port, Driver) -> {ok, Creation} | {error, Reason}
    when Name :: string(), Port :: non_neg_integer(), Driver :: atom(),
         Creation :: 1 .. 3, Reason :: address | file:posix()).
register_node(_Name, _Port, _Driver) ->
    {ok, 1}.

-spec(port_please(Name, Ip) -> {port, TcpPort, Version} | term()
    when Name :: string(), Ip :: inet:ip_address(),
         TcpPort :: inet:port_number(), Version :: 1 .. 5).
port_please("navstar", _Ip) ->
    {port, port(), ?DIST_PROTO_VSN};
port_please("dcos-net", _Ip) ->
    {port, port(), ?DIST_PROTO_VSN};
port_please(_None, _Ip) ->
    noport.

-spec(port() -> inet:port_number()).
port() ->
    {ok, Port} = dcos_net_app:dist_port(),
    Port.

%%====================================================================
%% EPMD Server
%%====================================================================

-define(EPMD_NAMES_REQ, $n).
-define(EPMD_PORT2_RESP, $w).
-define(EPMD_PORT_PLEASE2_REQ, $z).

start_link(Ref, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
    {ok, Pid}.

init(Ref, Socket, Transport, _Opts) ->
    ok = ranch:accept_ack(Ref),
    Transport:setopts(Socket, [{packet, 2}]),
    case Transport:recv(Socket, 0, 5000) of
        {ok, Data} ->
            Data0 = handle_epmd(Data),
            ok = Transport:setopts(Socket, [{packet, raw}]),
            Transport:send(Socket, Data0);
        {error, _Error} ->
            ok
    end,
    ok = Transport:close(Socket).

handle_epmd(<<?EPMD_NAMES_REQ>>) ->
    Format = "name ~s at port ~w~n",
    Data = [io_lib:format(Format, [Name, Port]) || {Name, Port} <- names()],
    ServerPort = ranch:get_port(?MODULE),
    [<<ServerPort:32>>, Data];
handle_epmd(<<?EPMD_PORT_PLEASE2_REQ, Name/binary>>) ->
    case lists:keymember(Name, 1, names()) of
        true -> reply_port_epmd(Name);
        false -> <<?EPMD_PORT2_RESP, 1>>
    end;
handle_epmd(_Data) ->
    <<>>.

reply_port_epmd(Name) ->
    {ok, Port} = dcos_net_app:dist_port(),
    NodeType = $M,
    Protocol = 0,
    HighVSN = ?DIST_PROTO_VSN,
    LowVSN = ?DIST_PROTO_VSN,
    Extra = <<>>,
    <<?EPMD_PORT2_RESP, 0, Port:16, NodeType:8,
      Protocol:8, HighVSN:16, LowVSN:16,
      (byte_size(Name)):16, Name/binary,
      (byte_size(Extra)):16, Extra/binary>>.

names() ->
    Hostname = dcos_net_dist:hostname(),
    {ok, Nodes} = names(binary_to_list(Hostname)),
    [{list_to_binary(Node), Port} || {Node, Port} <- Nodes].
