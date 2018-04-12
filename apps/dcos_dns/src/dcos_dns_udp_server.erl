-module(dcos_dns_udp_server).
-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-include("dcos_dns.hrl").

-record(state, {
    port :: inet:port_number(),
    socket :: gen_udp:socket()
}).

%%%===================================================================
%%% API
%%%===================================================================

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
    Fun = {fun gen_udp:send/4, [Socket, FromIP, FromPort]},
    _ = dcos_dns_handler:start(udp, Data, Fun),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State = #state{socket = Socket}) ->
    gen_udp:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
