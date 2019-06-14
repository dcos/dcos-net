-module(dcos_dns_udp_server).
-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3,
    handle_cast/2, handle_info/2]).

-include("dcos_dns.hrl").

-record(state, {
    socket :: gen_udp:socket(),
    gc_ref :: undefined | reference()
}).
-type state() :: #state{}.


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
    {ok, #state{socket = Socket}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({udp, Socket, FromIP, FromPort, Data},
            State = #state{socket = Socket}) ->
    Fun = {fun gen_udp:send/4, [Socket, FromIP, FromPort]},
    _ = dcos_dns_handler:start(udp, Data, Fun),
    {noreply, start_gc_timer(State)};
handle_info({timeout, GCRef, gc}, #state{gc_ref=GCRef}=State) ->
    {noreply, State#state{gc_ref=undefined}, hibernate};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_gc_timer(state()) -> state()).
start_gc_timer(#state{gc_ref = undefined} = State) ->
    Timeout = application:get_env(dcos_net, gc_timeout, 15000),
    TRef = erlang:start_timer(Timeout, self(), gc),
    State#state{gc_ref = TRef};
start_gc_timer(State) ->
    State.
