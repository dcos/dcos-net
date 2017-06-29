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
-export([init/3]).
-export([content_types_provided/2, allowed_methods/2, content_types_accepted/2]).
-export([to_json/2, perform_op/2]).

init(_Transport, Req, Opts) ->
    {upgrade, protocol, cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_accepted(Req, State) ->
    {[
        {{<<"text">>, <<"plain">>, []}, perform_op}
    ], Req, State}.

perform_op(Req, State) ->
    {Key, Req0} = key(Req),
    case cowboy_req:header(<<"clock">>, Req0, <<>>) of
        {<<>>, Req1} ->
            {{false, <<"Missing clock">>}, Req1, State};
        {Clock0, Req1} ->
            Clock1 = binary_to_term(base64:decode(Clock0)),
            {ok, Body0, Req2} = cowboy_req:body(Req1),
            Body1 = binary_to_list(Body0),
            {ok, Scanned, _} = erl_scan:string(Body1),
            {ok, Parsed} = erl_parse:parse_exprs(Scanned),
            {value, Update, _Bindings} = erl_eval:exprs(Parsed, erl_eval:new_bindings()),
            perform_op(Key, Update, Clock1, Req2, State)
    end.

perform_op(Key, Update, Clock, Req, State) ->
    case lashup_kv:request_op(Key, Clock, Update) of
        {ok, Value} ->
            Value0 = lists:map(fun encode_key/1, Value),
            {jsx:encode(Value0), Req, State};
        {error, concurrency} ->
            {{false, <<"Concurrent update">>}, Req, State}
    end.

    %io:format("HeaderVal: ~p", [HeaderVal]),


to_json(Req, State) ->
    {Key, Req0} = key(Req),
    fetch_key(Key, Req0, State).

fetch_key(Key, Req, State) ->
    {Value, Clock} = lashup_kv:value2(Key),
    Value0 = lists:map(fun encode_key/1, Value),
    ClockBin = base64:encode(term_to_binary(Clock)),
    Req0 = cowboy_req:set_resp_header(<<"clock">>, ClockBin, Req),
    {jsx:encode(Value0), Req0, State}.

key(Req) ->
    {KeyHandler, Req0} = cowboy_req:header(<<"key-handler">>, Req),
    {KeyData, Req1} = cowboy_req:path_info(Req0),
    {key(KeyData, KeyHandler), Req1}.

key([], _) ->
    erlang:throw(invalid_key);
key(KeyData, _) ->
    lists:map(fun(X) -> binary_to_atom(X, utf8) end, KeyData).

encode_key({{Name, Type = riak_dt_lwwreg}, Value}) ->
    #{value := Key} = encode_key(Name),
    {Key, [{type, Type}, {value, encode_key(Value)}]};
encode_key({{Name, Type = riak_dt_orswot}, Value}) ->
    #{value := Key} = encode_key(Name),
    {Key, [{type, Type}, {value, lists:map(fun encode_key/1, Value)}]};
encode_key(Value) when is_atom(Value) ->
    #{type => atom, value => Value};
encode_key(Value) when is_binary(Value) ->
    #{type => binary, value => Value};
encode_key(Value) when is_list(Value) ->
    #{type => string, value => list_to_binary(lists:flatten(Value))};
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

