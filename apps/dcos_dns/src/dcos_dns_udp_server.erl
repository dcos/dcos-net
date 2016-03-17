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

do_reply(To = {Pid, IP, Port}, Data) ->
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
    Port = application:get_env(?APP, udp_port, 5454),
    {ok, Socket} = gen_udp:open(Port, [{reuseaddr, true}, {active, true}, binary, {ip, LocalIP}]),
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
    case dcos_dns_handler_sup:start_child([{?MODULE, {self(), FromIP, FromPort}}, Data]) of
        {ok, Pid} when is_pid(Pid) ->
            dcos_dns_metrics:update([?MODULE, successes], 1, ?COUNTER),
            ok;
        Else ->
            lager:warning("Failed to start query handler: ~p", [Else]),
            dcos_dns_metrics:update([?MODULE, failures], 1, ?COUNTER),
            error
    end,
    {noreply, State};
handle_info(Info, State) ->
    lager:debug("Received info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

