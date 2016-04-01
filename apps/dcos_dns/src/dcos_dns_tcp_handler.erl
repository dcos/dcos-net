-module(dcos_dns_tcp_handler).
-behaviour(ranch_protocol).

-export([start_link/4,
         do_reply/2]).

-export([init/4]).

-record(state, {peer}).

-include("dcos_dns.hrl").
-define(TIMEOUT, 10000).

do_reply(Pid, Data) ->
    Pid ! {do_reply, Data}.

start_link(Ref, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
    {ok, Pid}.

init(Ref, Socket, Transport, _Opts = []) ->
    {ok, _} = timer:kill_after(?TIMEOUT),
    link(Socket),
    ok = ranch:accept_ack(Ref),
    ok = inet:setopts(Socket, [{packet, 2}, {active, true}]),
    {ok, Peer} = inet:peername(Socket),
    loop(Socket, Transport, #state{peer = Peer}).

loop(Socket, Transport, State) ->
    receive
        {tcp, Socket, Data} ->
            case dcos_dns_handler_sup:start_child([{?MODULE, self()}, Data]) of
                {ok, Pid} when is_pid(Pid) ->
                    dcos_dns_metrics:update([?MODULE, successes], 1, ?COUNTER),
                    monitor(process, Pid),
                    ok;
                Else ->
                    lager:warning("Failed to start query handler: ~p", [Else]),
                    dcos_dns_metrics:update([?MODULE, failures], 1, ?COUNTER),
                    error
            end,
            loop(Socket, Transport, State);
        {do_reply, ReplyData} ->
            Transport:send(Socket, ReplyData);
        {tcp_closed, Socket} ->
            ok;
        Else ->
            lager:debug("Received unknown data: ~p", [Else])
    %% Should the timeout here be more aggressive?
    after ?TIMEOUT ->
        Transport:close(Socket)
    end.
