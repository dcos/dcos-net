-module(dcos_dns_udp_server).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/1,
         do_reply/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("dcos_dns.hrl").

-record(state, {
    port = erlang:error() :: inet:port_number(),
    socket = erlang:error() :: gen_udp:socket()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec(do_reply(dcos_dns_handler_fsm:from_key(), binary()) -> ok).
do_reply(To = {Pid, {IP, Port}}, Data) ->
    lager:debug("Doing reply to ~p: ~p", [To, Data]),
    gen_server:cast(Pid, {send_behalf, IP, Port, Data}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
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

handle_cast({send_behalf, IP, Port, Data}, State = #state{socket = Socket}) ->
    gen_udp:send(Socket, IP, Port, Data),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({udp, RecvSocket, FromIP, FromPort, Data},
            State = #state{socket = Socket}) when Socket == RecvSocket ->
    From = {self(), {FromIP, FromPort}},
    case dcos_dns_handler_fsm:start({?MODULE, From}, Data) of
        {ok, Pid} when is_pid(Pid) ->
            ok;
        {error, overload} ->
            dcos_dns_metrics:update([?MODULE, overload], 1, ?COUNTER),
            error
    end,
    {noreply, State};
handle_info(Info, State) ->
    lager:debug("Received info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State = #state{socket = Socket}) ->
    gen_udp:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

