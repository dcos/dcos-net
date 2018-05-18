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
    family/1,
    get_leader_addr/0,
    resolve_mesos/1
]).

-spec family(inet:ip_address()) -> inet | inet6.
family(IP) when size(IP) == 4 ->
    inet;
family(IP) when size(IP) == 8 ->
    inet6.

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
