%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Jun 2016 11:50 PM
%%%-------------------------------------------------------------------
-module(dcos_dns).
-author("sdhillon").

%% API
-export([masters/0, is_master/0]).
-define(MASTERS_KEY, {masters, riak_dt_orswot}).


%% Always return an ordered set of masters
-spec(masters() -> [node()]).
masters() ->
    Masters = lashup_kv:value([masters]),
    case orddict:find(?MASTERS_KEY, Masters) of
        error ->
            [];
        {ok, Value} ->
            ordsets:from_list(Value)
    end.
-spec(is_master() -> boolean()).
is_master() ->
    ordsets:is_element(node(), masters()).