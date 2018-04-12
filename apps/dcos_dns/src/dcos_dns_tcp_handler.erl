-module(dcos_dns_tcp_handler).
-behaviour(ranch_protocol).
-behaviour(gen_statem).

-export([start_link/4]).

-export([init/1]).

-export([
    callback_mode/0,
    code_change/4,
    terminate/3
]).
-export([
    uninitialized/3,
    wait_for_query/3,
    waiting_for_reply/3
]).

-record(state, {
    socket,
    ref,
    transport,
    query_pid,
    query_monref
}).

-include("dcos_dns.hrl").
-define(TIMEOUT, 10000).
-define(SHUTDOWN(Reason), {shutdown, Reason}).

do_reply(Pid, Data) ->
    gen_statem:cast(Pid, {do_reply, Data}).

start_link(Ref, Socket, Transport, Opts) ->
    gen_statem:start_link(?MODULE, [Ref, Socket, Transport, Opts], []).

callback_mode() ->
    state_functions.

init([Ref, Socket, Transport, Opts]) ->
    link(Socket),
    State0 = #state{socket = Socket, transport = Transport, ref = Ref},
    {ok, uninitialized, State0, {next_event, internal, {do_init, Opts}}}.

uninitialized(internal, {do_init, _Opts = []}, State0 = #state{ref = Ref, socket = Socket}) ->
    ok = ranch:accept_ack(Ref),
    ok = inet:setopts(Socket, [{packet, 2}, {active, once}]),
    {next_state, wait_for_query, State0, {timeout, ?TIMEOUT, idle_timeout}}.

wait_for_query(timeout, idle_timeout, #state{transport = Transport, socket = Socket}) ->
    Transport:close(Socket),
    {stop, ?SHUTDOWN(idle_timeout)};
wait_for_query(info, {tcp_closed, Socket}, #state{socket = Socket}) ->
    {stop, ?SHUTDOWN(tcp_closed)};
wait_for_query(info, {tcp, Socket, Data}, State0 = #state{socket = Socket}) ->
    Fun = {fun do_reply/2, [self()]},
    case dcos_dns_handler:start(tcp, Data, Fun) of
        {ok, Pid} when is_pid(Pid) ->
            MonRef = erlang:monitor(process, Pid),
            State1 = State0#state{query_pid = Pid, query_monref = MonRef},
            {next_state, waiting_for_reply, State1, {timeout, ?TIMEOUT, query_timeout}};
        {error, overload} ->
            % NOTE: to avoid ddos spartan doesn't reply anything in case of overload
            {stop, overload}
    end;
wait_for_query(info, {'DOWN', _MonRef, process, _Pid, normal}, State) ->
    {next_state, wait_for_query, State, {timeout, ?TIMEOUT, idle_timeout}}.

waiting_for_reply(info, {'DOWN', _MonRef, process, _Pid, normal}, State) ->
    {next_state, waiting_for_reply, State, {timeout, ?TIMEOUT, query_timeout}};
waiting_for_reply(info, {'DOWN', _MonRef, process, Pid, Reason}, #state{query_pid = Pid}) ->
    {stop, ?SHUTDOWN(Reason)};
waiting_for_reply(timeout, query_timeout, #state{transport = Transport, socket = Socket}) ->
    Transport:close(Socket),
    {stop, ?SHUTDOWN(query_timeout)};
waiting_for_reply(info, {tcp_closed, Socket}, #state{socket = Socket, query_pid = Pid}) ->
    exit(Pid, normal),
    {stop, ?SHUTDOWN(tcp_closed)};
waiting_for_reply(cast, {do_reply, ReplyData}, State0 =
        #state{transport = Transport, socket = Socket, query_monref = MonRef}) ->
    Transport:send(Socket, ReplyData),
    inet:setopts(Socket, [{active, once}]),
    erlang:demonitor(MonRef, [flush]),
    {next_state, wait_for_query, State0, {timeout, ?TIMEOUT, idle_timeout}}.

terminate(_Reason, _State, #state{}) ->
    ok.

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.
