-module(dcos_dns_tcp_handler).
-behaviour(ranch_protocol).

-export([
    init/5,
    start_link/4
]).

-define(TIMEOUT, 10000).

start_link(Ref, Socket, Transport, Opts) ->
    Args = [self(), Ref, Socket, Transport, Opts],
    proc_lib:start_link(?MODULE, init, Args).

-spec(init(pid(), ranch:ref(), init:socket(),
           module(), ranch_tcp:opts()) -> ok).
init(Parent, Ref, Socket, Transport, Opts) ->
    erlang:link(Socket),
    ok = inet:setopts(Socket, [{packet, 2}, {send_timeout, ?TIMEOUT}]),
    proc_lib:init_ack(Parent, {ok, self()}),
    ok = ranch:accept_ack(Ref),
    loop(Socket, Transport, Opts).

-spec(loop(init:socket(), module(), ranch_tcp:opts()) -> ok).
loop(Socket, Transport, Opts) ->
    case Transport:recv(Socket, 0, ?TIMEOUT) of
        {ok, Request} ->
            case dcos_dns_handler:resolve(tcp, Request, ?TIMEOUT) of
                {ok, Response} ->
                    ok = Transport:send(Socket, Response),
                    loop(Socket, Transport, Opts);
                {error, Error} ->
                    exit(Error)
            end;
        {error, closed} ->
            ok;
        {error, Error} ->
            Transport:close(Socket),
            exit(Error)
    end.
