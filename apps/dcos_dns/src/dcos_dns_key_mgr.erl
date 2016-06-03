%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Jun 2016 11:27 PM
%%%-------------------------------------------------------------------
-module(dcos_dns_key_mgr).
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
-define(LASHUP_CHECK_INTERVAL, 5000).
-define(LASHUP_CHECKS, 12).
-define(LASHUP_KEY, [navstar, key]).
-define(ZOOKEEPER_TIMEOUT, 5000).
-define(ZOOKEEPER_PATH, "/navstar_key").
-define(ZOOKEEPERS,
    [{"master0.mesos", 2181}, {"master1.mesos", 2181}, {"master2.mesos", 2181}, {"master3.mesos", 2181}]).

-record(state, {lashup_checks = 0 :: non_neg_integer()}).

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
    self() ! check_lashup,
    {ok, #state{}}.

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
handle_info(check_lashup, State = #state{lashup_checks = 0}) ->
    case check_lashup_key()  of
        false ->
            lashup_kv ! bloom_wakeup,
            timer:send_after(?LASHUP_CHECK_INTERVAL, check_lashup);
        true ->
            {stop, normal, State}
    end;
handle_info(check_lashup, State = #state{lashup_checks = Checks}) when Checks < ?LASHUP_CHECKS ->
    case check_lashup_key() of
        false ->
            timer:send_after(?LASHUP_CHECK_INTERVAL, check_lashup),
            {noreply, State#state{lashup_checks = Checks + 1}};
        true ->
            {stop, normal, State}
    end;
handle_info(check_lashup, State) ->
    case maybe_zk() of
        true ->
            {stop, normal, State};
        false ->
            timer:send_after(?LASHUP_CHECK_INTERVAL, check_lashup),
            {noreply, State}
    end;
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

check_lashup_key() ->
    case lashup_kv:value(?LASHUP_KEY) of
        [] ->
            false;
        _ ->
            true
    end.

maybe_zk() ->
    IsMaster = dcos_dns:is_master(),
    case check_lashup_key() of
        true ->
            true;
        false when IsMaster ->
            create_zk_key();
        false ->
            false
    end.

create_zk_key() ->
    case erlzk:connect(?ZOOKEEPERS, ?ZOOKEEPER_TIMEOUT) of
        {ok, Pid} ->
            Ret = create_zk_key(Pid),
            erlzk:close(Pid),
            Ret;
        {error, Reason} ->
            lager:error("Unable to connect to zookeeper: ~p", [Reason]),
            false
    end.

create_zk_key(Pid) ->
    case erlzk:get_data(Pid, ?ZOOKEEPER_PATH) of
        {ok, {Data0, _State}} ->
            Data1 = #{public := _, secret := _} = jsx:decode(Data0, [return_maps, {labels, atom}]),
            push_data_to_lashup(Data1);
        {error, no_node} ->
            do_create_zk_key(Pid)
    end.

do_create_zk_key(Pid) ->
    KeyPair = #{public := _, secret := _} = enacl:sign_keypair(),
    Data = jsx:encode(KeyPair),
    case erlzk:create(Pid, ?ZOOKEEPER_PATH, Data) of
        {ok, _} ->
            push_data_to_lashup(KeyPair);
        Else ->
            %% This can actually just be a side effect of a concurrency violation
            %% Rather than trying to handle all the cases, we just try again later
            lager:warning("Unable to create zknode: ~p", [Else]),
            false
    end.

push_data_to_lashup(#{public := Pk, secret := Sk}) ->
    {ok, _} = lashup_kv:request_op(?LASHUP_KEY,
        {update, [
            {update, {public_key, riak_dt_lwwreg}, {assign, Pk, erlang:system_time(nano_seconds)}},
            {update, {secret_key, riak_dt_lwwreg}, {assign, Sk, erlang:system_time(nano_seconds)}}
            ]}),
    true.

