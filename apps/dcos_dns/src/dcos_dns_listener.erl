%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Jun 2016 3:37 AM
%%%-------------------------------------------------------------------
-module(dcos_dns_listener).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    ref = erlang:error() :: reference()
}).
-define(RPC_TIMEOUT, 5000).
-define(SPARTAN_RETRY, 30000).

-include("dcos_dns.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    {ok, Ref} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({[navstar, dns, zones, '_']}) -> true end)),
    {ok, #state{ref = Ref}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info({lashup_kv_events, Event = #{ref := Reference}}, State = #state{ref = Ref}) when Ref == Reference ->
    handle_event(Event),
    {noreply, State};
handle_info({retry_spartan, Key}, State) ->
    retry_spartan(Key),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

spartan_name() ->
    [_Node, Host] = binary:split(atom_to_binary(node(), utf8), <<"@">>),
    SpartanBinName = <<"spartan@", Host/binary>>,
    binary_to_atom(SpartanBinName, utf8).

zone2spartan(ZoneName, LashupValue) ->
    {_, Records} = lists:keyfind(?RECORDS_FIELD, 1, LashupValue),
    Sha = crypto:hash(sha, term_to_binary(Records)),
    {ZoneName, Sha, Records}.

handle_event(_Event = #{key := [navstar, dns, zones, ZoneName], value := Value}) ->
    Zone = zone2spartan(ZoneName, Value),
    spartan_push(Zone).

retry_spartan(Key = [navstar, dns, zones, ZoneName]) ->
    Value = lashup_kv:value(Key),
    Zone = zone2spartan(ZoneName, Value),
    spartan_push(Zone).

spartan_push(Zone = {ZoneName, _, _}) ->
    case rpc:call(spartan_name(), erldns_zone_cache, put_zone, [Zone], ?RPC_TIMEOUT) of
        Reason = {badrpc, _} ->
            lager:warning("Unable to push records to spartan: ~p", [Reason]),
            {ok, _} = timer:send_after(?SPARTAN_RETRY, {retry_spartan, [navstar, dns, zones, ZoneName]}),
            ok;
        ok ->
            ok
    end.


