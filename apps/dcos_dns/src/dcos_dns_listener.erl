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
    {ok, Ref} = lashup_kv:subscribe(MatchSpec),
    {noreply, #state{ref = Ref}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({lashup_kv_event, Ref, Key}, #state{ref = Ref} = State) ->
    ok = lashup_kv:flush(Ref, Key),
    Value = lashup_kv:value(Key),
    ok = handle_event(Key, Value),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(handle_event(Key :: term(), Value :: term()) -> ok | {error, term()}).
handle_event(?LASHUP_SET_KEY(ZoneName), Value) ->
    {?RECORDS_SET_FIELD, Records} = lists:keyfind(?RECORDS_SET_FIELD, 1, Value),
    dcos_dns:push_prepared_zone(ZoneName, Records);
handle_event(?LASHUP_LWW_KEY(ZoneName), Value) ->
    {?RECORDS_LWW_FIELD, Records} = lists:keyfind(?RECORDS_LWW_FIELD, 1, Value),
    dcos_dns:push_prepared_zone(ZoneName, Records).
