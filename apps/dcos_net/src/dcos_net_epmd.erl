-module(dcos_net_epmd).

-export([
    register_node/3,
    address_please/3,
    port_please/2,
    names/1
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

-spec(address_please(Name, Address, Family) -> {ok, IP} | term()
    when Name :: string(), Address :: string(), Family :: atom(),
         IP :: inet:ip_address()).
address_please(_Name, Address, _Family) ->
    inet:parse_ipv4_address(Address).

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
