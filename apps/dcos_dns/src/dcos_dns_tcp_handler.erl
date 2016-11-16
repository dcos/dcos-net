-module(dcos_dns_tcp_handler).
-behaviour(ranch_protocol).
-behaviour(gen_statem).

-export([start_link/4,
         do_reply/2]).

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
    query_pid
}).

-include("dcos_dns.hrl").
-define(TIMEOUT, 10000).

do_reply(Pid, Data) ->
    gen_statem:cast(Pid, {do_reply, Data}).

start_link(Ref, Socket, Transport, Opts) ->
    gen_statem:start_link(?MODULE, [Ref, Socket, Transport, Opts], []).

callback_mode() ->
    state_functions.

init([Ref, Socket, Transport, Opts]) ->
    {ok, _} = timer:kill_after(?TIMEOUT * 5),
    link(Socket),
    State0 = #state{socket = Socket, transport = Transport, ref = Ref},
    {ok, uninitialized, State0, {next_event, internal, {do_init, Opts}}}.

uninitialized(internal, {do_init, _Opts = []}, State0 = #state{ref = Ref, socket = Socket}) ->
    ok = ranch:accept_ack(Ref),
    ok = inet:setopts(Socket, [{packet, 2}, {active, once}]),
    {next_state, wait_for_query, State0, {timeout, ?TIMEOUT, idle_timeout}}.

wait_for_query(timeout, idle_timeout, #state{transport = Transport, socket = Socket}) ->
    Transport:close(Socket),
    {stop, idle_timeout};
wait_for_query(info, {tcp_closed, Socket}, #state{socket = Socket}) ->
    {stop, tcp_closed};
wait_for_query(info, {tcp, Socket, Data}, State0 = #state{socket = Socket}) ->
    case dcos_dns_handler_sup:start_child([{?MODULE, self()}, Data]) of
        {ok, Pid} when is_pid(Pid) ->
            dcos_dns_metrics:update([?MODULE, successes], 1, ?COUNTER),
            State1 = State0#state{query_pid = Pid},
            {next_state, waiting_for_reply, State1, {timeout, ?TIMEOUT, query_timeout}};
        Else ->
            lager:warning("Failed to start query handler: ~p", [Else]),
            dcos_dns_metrics:update([?MODULE, failures], 1, ?COUNTER),
            {stop, failed_to_start_query_handler}
    end.

waiting_for_reply(timeout, query_timeout, #state{transport = Transport, socket = Socket}) ->
    Transport:close(Socket),
    {stop, query_timeout};
waiting_for_reply(info, {tcp_closed, Socket}, #state{socket = Socket, query_pid = Pid}) ->
    exit(Pid, normal),
    {stop, tcp_closed};
waiting_for_reply(cast, {do_reply, ReplyData}, State0 = #state{transport = Transport, socket = Socket}) ->
    Transport:send(Socket, ReplyData),
    inet:setopts(Socket, [{active, once}]),
    {next_state, wait_for_query, State0, {timeout, ?TIMEOUT, idle_timeout}}.

terminate(_Reason, _State, #state{}) ->
    ok.

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.