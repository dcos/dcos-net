%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Jun 2016 6:05 PM
%%%-------------------------------------------------------------------
-module(dcos_rest_key_handler).
-author("sdhillon").

-include("dcos_rest.hrl").
%% API
-export([init/2]).
-export([content_types_provided/2, allowed_methods/2]).
-export([to_json/2]).


init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.


content_types_provided(Req, State) ->
    {[
        {<<"application/json">>, to_json}
    ], Req, State}.



allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.


to_json(Req0, State) ->
    Req1 =
        case keys() of
            notfound ->
                Body = <<"Cluster keys not found in Lashup">>,
                cowboy_req:reply(404, _Headers = [], Body, Req0);
            Body0 ->
                Body1 = jsx:encode(Body0),
                cowboy_req:reply(200, [], Body1, Req0)
    end,
    {<<>>, Req1, State}.

keys() ->
    MaybeNavstarKey = lashup_kv:value([navstar, key]),
    case {lists:keyfind({secret_key_zbase32, riak_dt_lwwreg}, 1, MaybeNavstarKey),
        lists:keyfind({public_key_zbase32, riak_dt_lwwreg}, 1, MaybeNavstarKey)} of
        {{_, SecretKey}, {_, PublicKey}} ->
            #{zbase32_public_key => PublicKey, zbase32_secret_key => SecretKey};
        _ ->
            notfound
    end.