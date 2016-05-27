%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 24. May 2016 9:34 PM
%%%-------------------------------------------------------------------
-module(dcos_rest_lashup_handler).
-author("sdhillon").

-include("dcos_rest.hrl").
%% API
-export([init/2]).
-export([content_types_provided/2, allowed_methods/2, content_types_accepted/2]).
-export([to_json/2, perform_op/2]).


init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.


content_types_provided(Req, State) ->
    {[
        {<<"application/json">>, to_json}
    ], Req, State}.


allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_accepted(Req, State) ->
    {[
        {<<"text/plain">>, perform_op}
    ], Req, State}.

perform_op(Req, State) ->
    <<"POST">> = cowboy_req:method(Req),
    Key = key(Req),
    _ = Key,
    true = cowboy_req:has_body(Req),
    case cowboy_req:header(<<"clock">>, Req, <<>>) of
        <<>> ->
            {{false, <<"Missing clock">>}, Req, State};
        Clock0 ->
            Clock1 = binary_to_term(base64:decode(Clock0)),
            {ok, Body0, Req2} = cowboy_req:body(Req),
            Body1 = binary_to_list(Body0),
            {ok, Scanned, _} = erl_scan:string(Body1),
            {ok,Parsed} = erl_parse:parse_exprs(Scanned),
            {value, Update, _Bindings} = erl_eval:exprs(Parsed, erl_eval:new_bindings()),
            perform_op(Key, Update, Clock1, Req2, State)
    end.

perform_op(Key, Update, Clock, Req, State) ->
    case lashup_kv:request_op(Key, Clock, Update) of
        {ok, Value0} ->
            Value1 = lists:map(fun encode_key/1, Value0),
            Body = jsx:encode(Value1),
            Req2 = cowboy_req:reply(200, [], Body, Req),
            {<<>>, Req2, State};
        {error, concurrency} ->
            {{false, <<"Concurrent update">>}, Req, State}
    end.

    %io:format("HeaderVal: ~p", [HeaderVal]),


to_json(Req, State) ->
    Key = key(Req),
    fetch_key(Key, Req, State).

fetch_key(Key, Req, State) ->
    {Value0, Clock} = lashup_kv:value2(Key),
    Value1 = lists:map(fun encode_key/1, Value0),
    Body = jsx:encode(Value1),
    Req2 = cowboy_req:reply(200, [
        {<<"clock">>, base64:encode(term_to_binary(Clock))}
    ], Body, Req),
    io:format("Req2: ~p~n", [Req2]),
    {<<>>, Req2, State}.

key(Req) ->
    KeyHandler = cowboy_req:header(<<"key-handler">>, Req),
    KeyData = cowboy_req:path_info(Req),
    key(KeyData, KeyHandler).

key([], _) ->
    erlang:throw(invalid_key);
key(KeyData, _) ->
    lists:map(fun(X) -> binary_to_atom(X, utf8) end, KeyData).


encode_key({{Name, Type = riak_dt_lwwreg}, Value}) ->
    {Name, [{type, Type}, {value, encode_key(Value)}]};
encode_key({{Name, Type = riak_dt_orswot}, Value}) ->
    {Name, [{type, Type}, {value, lists:map(fun encode_key/1, Value)}]};

encode_key(Value) when is_atom(Value) ->
    #{
        type => atom,
        value => Value
    };
encode_key(Value) when is_binary(Value) ->
    #{
        type => binary,
        value => Value
    };
encode_key(Value) when is_list(Value) ->
    #{
        type => string,
        value => list_to_binary(lists:flatten(Value))
    };
%% Probably an IP address?
encode_key(IP = {A, B, C, D}) when is_integer(A) andalso is_integer(B) andalso is_integer(C) andalso is_integer(D)
    andalso A >= 0 andalso B >= 0 andalso C >= 0 andalso D >= 0
    andalso A =< 255 andalso B =< 255 andalso C =< 255 andalso D =< 255 ->
    #{
        type => ipaddress_tuple,
        value => list_to_binary(lists:flatten(inet:ntoa(IP)))
    };
encode_key(Value) when is_tuple(Value) ->
    #{
        type => tuple,
        value => list_to_binary(lists:flatten(io_lib:format("~p", [Value])))
    };
encode_key(Value) when is_tuple(Value) ->
    #{
        type => unknown,
        value => list_to_binary(lists:flatten(io_lib:format("~p", [Value])))
    }.

