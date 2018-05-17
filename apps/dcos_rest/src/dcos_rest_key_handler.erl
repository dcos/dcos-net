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

-export([
    init/2,
    content_types_provided/2,
    allowed_methods/2,
    to_json/2
]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

to_json(Req, State) ->
    case dcos_dns_key_mgr:keys() of
        #{public_key := PublicKey, secret_key := SecretKey} ->
            Data = #{zbase32_public_key => zbase32:encode(PublicKey),
                     zbase32_secret_key => zbase32:encode(SecretKey)},
            {jsx:encode(Data), Req, State};
        false ->
            Body = <<"Cluster keys not found in Lashup">>,
            Req0 = cowboy_req:reply(404, #{}, Body, Req),
            {stop, Req0, State}
    end.
