%%% @doc Kills stuck processes

-module(dcos_net_killer).
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3]).

-record(state, {
    ref :: reference(),
    reductions :: #{pid() => non_neg_integer()}
}).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Ref = erlang:start_timer(0, self(), kill),
    {ok, #state{ref=Ref, reductions=#{}}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({timeout, Ref, kill}, #state{ref=Ref, reductions=Prev}=State) ->
    Rs = reductions(),
    StuckProcesses =
        maps:fold(fun (Pid, R, Acc) ->
            case maps:find(Pid, Prev) of
                {ok, R} -> [Pid|Acc];
                _Other -> Acc
            end
        end, [], Rs),
    lists:foreach(fun maybe_kill/1, StuckProcesses),
    Timeout = application:get_env(dcos_net, killer_timeout, timer:minutes(5)),
    Ref0 = erlang:start_timer(Timeout, self(), kill),
    {noreply, State#state{ref=Ref0, reductions=Rs}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(reductions() -> #{pid() => non_neg_integer()}).
reductions() ->
    lists:foldl(fun (Pid, Acc) ->
        case erlang:process_info(Pid, reductions) of
            {reductions, R} ->
                Acc#{Pid => R};
            undefined -> Acc
        end
    end, #{}, erlang:processes()).

-spec(maybe_kill(pid()) -> true | no_return()).
maybe_kill(Pid) ->
    case erlang:process_info(Pid, current_function) of
        {current_function, MFA} ->
            maybe_kill(Pid, MFA);
        undefined -> true
    end.

-spec(maybe_kill(pid(), mfa()) -> true | no_return()).
maybe_kill(Pid, MFA) ->
    case stuck_fun(MFA) of
        true -> kill(Pid, MFA);
        false -> true
    end.

-spec(kill(pid(), mfa()) -> true | no_return()).
kill(Pid, MFA) ->
    lager:alert("~p got stuck: ~p", [Pid, MFA]),
    case application:get_env(dcos_net, killer, disabled) of
        disabled -> true;
        enabled -> exit(Pid, kill);
        {enabled, abort} -> erlang:halt(abort)
    end.

-spec(stuck_fun(mfa()) -> boolean()).
stuck_fun({erlang, hibernate, 3}) -> false;
stuck_fun({erts_code_purger, wait_for_request, 0}) -> false;
stuck_fun({gen_event, fetch_msg, 6}) -> false;
stuck_fun({prim_inet, accept0, _}) -> false;
stuck_fun({prim_inet, recv0, 2}) -> false;
stuck_fun({timer, sleep, 1}) -> false;
stuck_fun({group, _F, _A}) -> false;
stuck_fun({global, _F, _A}) -> false;
stuck_fun({prim_eval, _F, _A}) -> false;
stuck_fun({io, _F, _A}) -> false;
stuck_fun({shell, _F, _A}) -> false;
stuck_fun({recon_trace, _F, _A}) -> false;
stuck_fun({_M, F, _A}) ->
    Fun = atom_to_binary(F, latin1),
    binary:match(Fun, <<"loop">>) =:= nomatch.
