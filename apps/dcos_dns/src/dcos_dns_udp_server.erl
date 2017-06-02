-module(dcos_dns_udp_server).
-behaviour(gen_server).

%% API
-export([
    start_link/1,
    do_reply/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("dcos_dns.hrl").

-record(state, {
    port :: inet:port_number(),
    socket :: gen_udp:socket()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec(do_reply({Socket, IP, Port}, Data :: iodata()) -> not_owner | inet:posix()
    when Socket :: gen_udp:socket(), IP ::  inet:socket_address() | inet:hostname(),
         Port :: inet:port_number()).
do_reply({Socket, IP, Port}, Data) ->
    gen_udp:send(Socket, IP, Port, Data).

-spec(start_link(LocalIP :: inet:ip4_address()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(LocalIP) ->
    gen_server:start_link(?MODULE, [LocalIP], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([LocalIP]) ->
    Port = dcos_dns_config:udp_port(),
    RecBuf = application:get_env(dcos_dns, udp_recbuf, 1024 * 1024),
    {ok, Socket} = gen_udp:open(Port, [
        {reuseaddr, true}, {active, true}, binary,
        {ip, LocalIP}, {recbuf, RecBuf}
    ]),
    link(Socket),
    {ok, #state{port = Port, socket = Socket}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({udp, Socket, FromIP, FromPort, Data},
            State = #state{socket = Socket}) ->
    From = {Socket, FromIP, FromPort},
    case dcos_dns_handler_fsm:start({?MODULE, From}, Data) of
        {ok, Pid} when is_pid(Pid) ->
            ok;
        {error, overload} ->
            dcos_dns_metrics:update([?MODULE, overload], 1, ?COUNTER),
            error
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State = #state{socket = Socket}) ->
    gen_udp:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
