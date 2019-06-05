-module(dcos_dns_listener).
-behaviour(gen_server).

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_continue/2,
    handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    ref = erlang:error() :: reference()
}).

-include("dcos_dns.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

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
    MatchSpec =
        case dcos_dns_config:store_modes() of
            [lww | _Modes] ->
                ets:fun2ms(fun ({?LASHUP_LWW_KEY('_')}) -> true end);
            [set | _Modes] ->
                ets:fun2ms(fun ({?LASHUP_SET_KEY('_')}) -> true end)
        end,
    {ok, Ref} = lashup_kv_events_helper:start_link(MatchSpec),
    {noreply, #state{ref = Ref}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({lashup_kv_events, Event = #{ref := Ref, key := Key}},
        State = #state{ref = Ref}) ->
    Event0 = skip_kv_event(Event, Ref, Key),
    ok = handle_event(Event0),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(skip_kv_event(Event, reference(), term()) -> Event when Event :: map()).
skip_kv_event(Event, Ref, Key) ->
    % Skip current lashup kv event if there is yet another event in
    % the message queue. It should improve the convergence.
    receive
        {lashup_kv_events, #{ref := Ref, key := Key} = Event0} ->
            skip_kv_event(Event0, Ref, Key)
    after 0 ->
        Event
    end.

-spec(handle_event(map()) -> ok).
handle_event(#{key := ?LASHUP_SET_KEY(ZoneName), value := Value}) ->
    {?RECORDS_SET_FIELD, Records} = lists:keyfind(?RECORDS_SET_FIELD, 1, Value),
    dcos_dns:push_prepared_zone(ZoneName, Records);
handle_event(#{key := ?LASHUP_LWW_KEY(ZoneName), value := Value}) ->
    {?RECORDS_LWW_FIELD, Records} = lists:keyfind(?RECORDS_LWW_FIELD, 1, Value),
    dcos_dns:push_prepared_zone(ZoneName, Records).
