-module(dcos_sfs_metadata).
-include_lib("stdlib/include/ms_transform.hrl").

-export([
    read/1,
    save/2,
    stream/1
]).

-export_type([
    send_fun/0,
    metadata/0
]).

-define(SFS_KEY, sfs).

-type send_fun() :: (fun (([binary()], metadata()) -> ok | {error, atom()})).
-type metadata() :: term().


-spec(read(Path :: [binary()]) -> {ok, metadata()} | error).
read(Path) ->
    Value = lashup_kv:value(?SFS_KEY),
    Field = {Path, riak_dt_lwwreg},
    orddict:find(Field, Value).

-spec(save(Path :: [binary()], metadata()) -> ok | {error, term()}).
save(Path, Metadata) ->
    {_Value, VClock} = lashup_kv:value2(?SFS_KEY),
    save(Path, Metadata, VClock).

-spec(save(Path :: [binary()], metadata(), VClock) -> ok | {error, term()}
    when VClock :: riak_dt_vclock:vclock()).
save(Path, Metadata, VClock) ->
    Metadata0 =
        maps:filter(
            fun (_Key, Value) ->
                Value =/= undefined
            end, Metadata),
    Field = {Path, riak_dt_lwwreg},
    Time = erlang:system_time(nano_seconds),
    Updates = [{update, Field, {assign, Metadata0, Time}}],
    case request_op(VClock, {update, Updates}) of
        {ok, _} -> ok;
        {error, Error} ->
            {error, Error}
    end.

-spec(request_op(Context :: riak_dt_vclock:vclock(), Op :: riak_dt_map:map_op()) ->
    {ok, riak_dt_map:value()} | {error, Reason :: term()}).
request_op(VClock, Ops) ->
    lashup_kv:request_op(?SFS_KEY, VClock, Ops).

%%%===================================================================
%%% Streaming
%%%===================================================================

-spec(stream(send_fun()) -> ok).
stream(Fun) ->
    MatchSpec = ets:fun2ms(fun({?SFS_KEY}) -> true end),
    {ok, Ref} = lashup_kv_events_helper:start_link(MatchSpec),
    stream(Fun, Ref, #{}).

-spec(stream(send_fun(), reference(), State :: #{}) -> ok).
stream(Fun, Ref, State) ->
    receive
        {lashup_kv_events, Event} ->
            #{ref := Ref, value := Value} = Event,
            Acc = {ok, Fun, State},
            case lists:foldl(fun stream_fold_fun/2, Acc, Value) of
                {ok, _Fun, State0} ->
                    stream(Fun, Ref, State0);
                {error, _Fun, closed} ->
                    ok
            end
    end.

-spec(stream_fold_fun(Value, Acc) -> Acc
    when Value :: {lashup_kv:key(), #{}}, State :: #{},
         Acc :: {ok, send_fun(), State} | {error, send_fun(), atom()}).
stream_fold_fun(_Value, {error, Fun, Error}) ->
    {error, Fun, Error};
stream_fold_fun({{Path, riak_dt_lwwreg}, Metadata}, {ok, Fun, State}) ->
    Hash = erlang:phash2(Metadata),
    case maps:find(Path, State) of
        {ok, Hash} ->
            {ok, Fun, State};
        _ ->
            case Fun(Path, Metadata) of
                ok ->
                    {ok, Fun, State#{Path => Hash}};
                {error, Error} ->
                    {error, Fun, Error}
            end
    end.
