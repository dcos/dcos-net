%% Basic utility module to integrate with systemd sd_notify via shell commands

-module(dcos_dns_systemd).
-author("Sargun Dhillon <sargun@mesosphere.com>").
-behaviour(gen_server).


%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

%% API
-export([start_link/0]).

-include("dcos_dns.hrl").

-define(REFRESH_INTERVAL, 15000).
-define(REFRESH_MESSAGE,  refresh).


%% State record.
-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    ready(),
    timer:send_after(?REFRESH_INTERVAL, ?REFRESH_MESSAGE),
    {ok, #state{}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.

%% @private
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(?REFRESH_MESSAGE, State) ->
    wakeup_watchdog(),
    timer:send_after(?REFRESH_INTERVAL, ?REFRESH_MESSAGE),
    {noreply, State};
handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% API
systemd_enabled() ->
    case os:find_executable("systemd-notify") of
        false ->
            false;
        ExecPath ->
            ExecPath
    end.


wakeup_watchdog() ->
    case systemd_enabled() of
        false ->
            ok;
        ExecPath ->
            ok = healthcheck(),
            os:cmd(systemd_command(ExecPath, "WATCHDOG=1"))
    end.



ready() ->
    case systemd_enabled() of
        false ->
            ok;
        ExecPath ->
            os:cmd(systemd_command(ExecPath, "READY=1 WATCHDOG=1"))
    end.


systemd_command(ExecPath, Opts) ->
    Pid = os:getpid(),
    lists:flatten(io_lib:format("~s MAINPID=~s ~s", [ExecPath, Pid, Opts])).


healthcheck() ->
    ok = maybe_udp_healthcheck(),
    ok = maybe_tcp_healthcheck(),
    ok.

maybe_tcp_healthcheck() ->
    case dcos_dns_config:tcp_enabled() of
        true ->
            ok = tcp_healthcheck();
        _ ->
            ok
    end.

maybe_udp_healthcheck() ->
    case application:get_env(?APP, udp_server_enabled, true) of
        true ->
            ok = udp_healthcheck();
        _ ->
            ok
    end.

tcp_healthcheck() ->
    TCPPort = dcos_dns_config:tcp_port(),
    DNSOpts = [
        {nameservers, [{{127, 0, 0, 1}, TCPPort}]},
        {timeout, 1000},
        {usevc, true}
    ],
    [{127, 0, 0, 1}] = inet_res:lookup("ready.spartan", in, a, DNSOpts),
    ok.


udp_healthcheck() ->
    UDPPort = dcos_dns_config:udp_port(),
    DNSOpts = [
        {nameservers, [{{127, 0, 0, 1}, UDPPort}]},
        {timeout, 1000},
        {usevc, false}
    ],
    [{127, 0, 0, 1}] = inet_res:lookup("ready.spartan", in, a, DNSOpts),
    ok.


