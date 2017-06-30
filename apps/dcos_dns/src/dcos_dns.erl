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
-export([
    masters/0,
    is_master/0,
    key/0,
    get_leader_addr/0,
    resolve_mesos/1
]).
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

key() ->
    MaybeNavstarKey = lashup_kv:value([navstar, key]),
    case {lists:keyfind({secret_key, riak_dt_lwwreg}, 1, MaybeNavstarKey),
        lists:keyfind({public_key, riak_dt_lwwreg}, 1, MaybeNavstarKey)} of
        {{_, SecretKey}, {_, PublicKey}} ->
            #{public_key => PublicKey, secret_key => SecretKey};
        _ ->
            false
    end.

-spec(get_leader_addr() -> {ok, inet:ip_address()} | {error, term()}).
get_leader_addr() ->
    resolve_mesos("leader.mesos").

-spec(resolve_mesos(inet_res:dns_name()) ->
    {ok, inet:ip_address()} | {error, term()}).
resolve_mesos(DNSName) ->
    Opts = [{nameservers, dcos_dns_config:mesos_resolvers()}],
    case inet_res:resolve(DNSName, in, a, Opts, 1000) of
        {ok, DnsMsg} ->
            case inet_dns:msg(DnsMsg, anlist) of
                [DnsRecord] ->
                    {ok, inet_dns:rr(DnsRecord, data)};
                _DnsRecords ->
                    {error, not_found}
            end;
        Error ->
            Error
    end.
