-module(dcos_overlay_lashup_kv_listener).
-behaviour(gen_server).

-include_lib("stdlib/include/ms_transform.hrl").

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_continue/2,
    handle_call/3, handle_cast/2, handle_info/2]).

-export_type([subnet/0, config/0]).

-define(KEY(Subnet), [navstar, overlay, Subnet]).

-type subnet() :: {inet:ip_address(), 0..32}.
-type config() :: #{
    OverlaySubnet :: subnet() =>
        {VTEPIPPrefix :: subnet(), #{
            agent_ip => inet:ip_address(),
            mac => list(0..16#FF),
            subnet => subnet()
        }}
    }.

-record(state, {
    ref :: reference(),
    config = #{} :: config(),
    reconcile_ref :: reference()
}).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, {}, {continue, {}}}.

handle_continue({}, {}) ->
    ok = wait_for_vtep(),
    MatchSpec = ets:fun2ms(fun({?KEY('_')}) -> true end),
    {ok, Ref} = lashup_kv:subscribe(MatchSpec),
    RRef = start_reconcile_timer(),
    {noreply, #state{ref=Ref, reconcile_ref=RRef}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({lashup_kv_event, Ref, Key},
        #state{ref=Ref, config=Config}=State) ->
    ok = lashup_kv:flush(Ref, Key),
    Value = lashup_kv:value(Key),
    {Subnet, Delta, Config0} = update_config(Key, Value, Config),
    ok = apply_configuration(#{Subnet => Delta}),
    {noreply, State#state{config=Config0}};
handle_info({timeout, RRef0, reconcile},
        #state{config=Config, reconcile_ref=RRef0}=State) ->
    ok = apply_configuration(Config),
    RRef = start_reconcile_timer(),
    {noreply, State#state{reconcile_ref=RRef}, hibernate};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-define(WAIT_TIMEOUT, 5000).

-spec(wait_for_vtep() -> ok).
wait_for_vtep() ->
    % listener must wait until vtep is configured.
    % dcos_overlay_poller polls local mesos agent module and
    % configures vtep interfaces.
    try dcos_overlay_poller:overlays() of
        [] ->
            timer:sleep(?WAIT_TIMEOUT),
            wait_for_vtep();
        _Overlays ->
            ok
    catch _Class:_Error ->
        wait_for_vtep()
    end.

-spec(start_reconcile_timer() -> reference()).
start_reconcile_timer() ->
    Timeout =
        application:get_env(dcos_overlay, reconcile_timeout, timer:minutes(5)),
    erlang:start_timer(Timeout, self(), reconcile).

-spec(update_config(Key :: term(), Value :: [term()], config()) ->
    {subnet(), Delta :: [{subnet(), map()}], config()}).
update_config(?KEY(Subnet), Value, Config) ->
    OldValue = maps:get(Subnet, Config, []),
    NewValue =
        [ {IP, maps:from_list(
             [{K, V} || {{K, riak_dt_lwwreg}, V} <- L])}
        || {{IP, riak_dt_map}, L} <- Value ],
    {Delta, _} = dcos_net_utils:complement(NewValue, OldValue),
    lists:foreach(fun ({VTEP, Data}) ->
        Info = maps:map(fun (_K, V) -> to_str(V) end, Data#{vtep => VTEP}),
        lager:notice(
            "Overlay configuration was gossiped, subnet: ~s data: ~p",
            [to_str(Subnet), Info])
    end, Delta),
    {Subnet, Delta, Config#{Subnet => NewValue}}.

-spec(apply_configuration(config()) -> ok).
apply_configuration(Config) ->
    Timeout =
        application:get_env(dcos_overlay, apply_timeout, timer:minutes(5)),
    Pid = dcos_overlay_configure:start_link(Config),
    receive
        {dcos_overlay_configure, applied_config, _Config} ->
            ok
    after Timeout ->
        lager:error("dcos_overlay_configure got stuck applying ~p", [Config]),
        exit(Pid, kill)
    end.

-spec(to_str(term()) -> string()).
to_str({IP, Prefix}) ->
    lists:concat([inet:ntoa(IP), "/", Prefix]);
to_str(Mac) when length(Mac) =:= 6 ->
    List = [[integer_to_list(A div 16, 16),
             integer_to_list(A rem 16, 16)]
           || A <- Mac],
    lists:flatten(string:join(List, ":"));
to_str(IP) ->
    inet:ntoa(IP).
