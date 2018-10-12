-module(dcos_dns_key_mgr).
-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/0,
         keys/0]).

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
-define(DEFAULT_ZOOKEEPER_SERVERS, [
    {"master0.mesos", 2181},
    {"master1.mesos", 2181},
    {"master2.mesos", 2181},
    {"master3.mesos", 2181}
]).

-record(state, {lashup_checks = 0 :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec keys() -> #{public_key => binary(), secret_key => binary()} | false.
keys() ->
    MaybeNavstarKey = lashup_kv:value(?LASHUP_KEY),
    case {lists:keyfind({secret_key, riak_dt_lwwreg}, 1, MaybeNavstarKey),
        lists:keyfind({public_key, riak_dt_lwwreg}, 1, MaybeNavstarKey)} of
        {{_, SecretKey}, {_, PublicKey}} ->
            #{public_key => PublicKey, secret_key => SecretKey};
        _ ->
            false
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! check_lashup,
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(check_lashup, State = #state{lashup_checks = 0}) ->
    case check_lashup_key()  of
        false ->
            lashup_kv ! bloom_wakeup,
            timer:send_after(?LASHUP_CHECK_INTERVAL, check_lashup),
            {noreply, State#state{lashup_checks = 1}};
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

terminate(_Reason, _State) ->
    ok.

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
    IsMaster = dcos_net_app:is_master(),
    case check_lashup_key() of
        true ->
            true;
        false when IsMaster ->
            create_zk_key();
        false ->
            false
    end.

create_zk_key() ->
    ZooKeepers = get_zookeepers(),
    case erlzk:connect(ZooKeepers, ?ZOOKEEPER_TIMEOUT) of
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
        {ok, {Data, _Stat}} ->
            KeyPair = decode(Data),
            push_data_to_lashup(KeyPair);
        {error, no_node} ->
            do_create_zk_key(Pid);
        {error, closed} ->
            lager:warning("Unable to get data from zk: closed"),
            false
    end.

do_create_zk_key(Pid) ->
    KeyPair = #{public := _, secret := _} = enacl:sign_keypair(),
    Data = encode(KeyPair),
    case erlzk:create(Pid, ?ZOOKEEPER_PATH, Data) of
        {ok, _} ->
            push_data_to_lashup(KeyPair);
        Else ->
            %% This can actually just be a side effect of a concurrency violation
            %% Rather than trying to handle all the cases, we just try again later
            lager:warning("Unable to create zknode: ~p", [Else]),
            false
    end.

encode(#{public := Pk, secret := Sk}) ->
    {latin1, 0} = unicode:bom_to_encoding(Pk),
    PkUtf8 = unicode:characters_to_binary(Pk, latin1, utf8),
    SkUtf8 = unicode:characters_to_binary(Sk, latin1, utf8),
    jsx:encode(#{public => PkUtf8, secret => SkUtf8}).

decode(Data) ->
    #{public := PkUtf8, secret := SkUtf8} =
        jsx:decode(Data, [return_maps, {labels, atom}]),
    Pk = unicode:characters_to_binary(PkUtf8, utf8, latin1),
    Sk = unicode:characters_to_binary(SkUtf8, utf8, latin1),
    #{public => Pk, secret => Sk}.

push_data_to_lashup(#{public := Pk, secret := Sk}) ->
    PkZBase32 = zbase32:encode(Pk),
    SkZBase32 = zbase32:encode(Sk),
    {ok, _} = lashup_kv:request_op(?LASHUP_KEY,
        {update, [
            {update, {public_key, riak_dt_lwwreg}, {assign, Pk, erlang:system_time(nano_seconds)}},
            {update, {secret_key, riak_dt_lwwreg}, {assign, Sk, erlang:system_time(nano_seconds)}},
            {update, {public_key_zbase32, riak_dt_lwwreg}, {assign, PkZBase32, erlang:system_time(nano_seconds)}},
            {update, {secret_key_zbase32, riak_dt_lwwreg}, {assign, SkZBase32, erlang:system_time(nano_seconds)}}
            ]}),
    true.

get_zookeepers() ->
    ZooKeeperServers = application:get_env(dcos_dns, zookeeper_servers,
                                           ?DEFAULT_ZOOKEEPER_SERVERS),
    lists:map(fun ({Host, Port}) ->
        case dcos_dns:resolve_mesos(Host) of
            {ok, IPAddr} ->
                {inet:ntoa(IPAddr), Port};
            {error, _} ->
                {Host, Port}
        end
    end, ZooKeeperServers).

-ifdef(TEST).

key_encode_decode_test() ->
    Pk = <<58, 115, 64, 205, 205, 51, 217, 239, 36, 69, 93, 229, 152, 194, 108,
           61, 86, 255, 28, 129, 123, 240, 134, 128, 147, 202, 192, 9>>,
    Sk = <<12, 9, 70, 206, 126, 233, 39, 196, 40, 230, 232, 203, 108, 13, 13,
             193, 210, 119, 243, 195, 63, 26, 6, 160, 56, 226, 47>>,
    KeyPair = #{public => Pk, secret => Sk},
    Encoded = encode(KeyPair),
    Result = decode(Encoded),
    ?assertEqual(KeyPair, Result).

-endif.
