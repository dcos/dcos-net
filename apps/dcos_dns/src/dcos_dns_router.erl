-module(dcos_dns_router).
-author("sdhillon").

-include("dcos_dns.hrl").

-include_lib("kernel/include/logger.hrl").
-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% API
-export([upstreams_from_questions/1]).

%% @doc Resolvers based on a set of "questions"
-spec(upstreams_from_questions(dns:questions()) ->
    {[upstream()] | internal, binary()} | {rename, binary(), binary()}).
upstreams_from_questions([#dns_query{name=Name}]) ->
    Labels = dcos_dns_app:parse_upstream_name(Name),
    find_upstream(Labels);
upstreams_from_questions(Questions) ->
    AllUpstreams = [upstreams_from_questions([Q]) || Q <- Questions],
    case lists:usort(AllUpstreams) of
        [Upstream] ->
            Upstream;
        _Upstreams ->
            ?LOG_WARNING(
                "DNS queries with mixed-upstream questions are not supported, "
                "the query will be resolved through internal DNS server: ~p",
                [Questions]),
            lists:foreach(fun (Zone) ->
                prometheus_counter:inc(
                    dns, forwarder_failures_total,
                    [Zone], 1)
            end, [Z || {U, Z} <- AllUpstreams, U =/= internal]),
            {internal, <<".">>}
    end.

-spec(validate_upstream(upstream()) -> upstream()).
validate_upstream({{_, _, _, _}, Port} = Upstream) when is_integer(Port) ->
    Upstream.

%% @private
-spec(default_resolvers() -> [upstream()]).
default_resolvers() ->
    Defaults = [{{8, 8, 8, 8}, 53},
                {{4, 2, 2, 1}, 53},
                {{8, 8, 8, 8}, 53},
                {{4, 2, 2, 1}, 53},
                {{8, 8, 8, 8}, 53}],
    Resolvers = application:get_env(?APP, upstream_resolvers, Defaults),
    lists:map(fun validate_upstream/1, Resolvers).

%% @private
-spec(find_upstream(Labels :: [binary()]) ->
    {[upstream()] | internal, binary()} | {rename, binary(), binary()}).
find_upstream([<<"directory">>, <<"thisdcos">>, <<"dclb">> |_]) ->
    {rename, <<"dclb.thisdcos.directory.">>, <<"l4lb.thisdcos.directory.">>};
find_upstream([<<"global">>, <<"thisdcos">>, <<"dclb">> |_]) ->
    {rename, <<"dclb.thisdcos.global.">>, <<"l4lb.thisdcos.directory.">>};
find_upstream([<<"global">>, <<"thisdcos">>, Label |_]) ->
    From = <<Label/binary, ".thisdcos.global.">>,
    To = <<Label/binary, ".thisdcos.directory.">>,
    {rename, From,  To};
find_upstream([<<"directory">>, <<"dcos">>, Id, Label |_] = Labels) ->
    case cluster_crypto_id() of
        Id ->
            From = <<Label/binary, ".", Id/binary, ".dcos.directory.">>,
            To = <<Label/binary, ".thisdcos.directory.">>,
            {rename, From, To};
        _CryptoId ->
            maybe_find_custom_upstream(Labels)
    end;
find_upstream([<<"mesos">>|_]) ->
   {dcos_dns_config:mesos_resolvers(), <<"mesos.">>};
find_upstream([<<"localhost">>|_]) ->
    {internal, <<"localhost.">>};
find_upstream([<<"zk">>|_]) ->
    {internal, <<"zk.">>};
find_upstream([<<"spartan">>|_]) ->
    {internal, <<"spartan.">>};
find_upstream([<<"directory">>, <<"thisdcos">>, Label |_]) ->
    {internal, <<Label/binary, ".thisdcos.directory.">>};
find_upstream(Labels) ->
    maybe_find_custom_upstream(Labels).

-spec(maybe_find_custom_upstream([binary()]) -> {[upstream()], binary()}).
maybe_find_custom_upstream(Labels) ->
    case find_custom_upstream(Labels) of
        {[], _ZoneLabels} ->
            {default_resolvers(), <<".">>};
        {Resolvers, ZoneLabels} ->
            ReverseZoneLabels = lists:reverse([<<>> | ZoneLabels]),
            Zone = dcos_net_utils:join(ReverseZoneLabels, <<".">>),
            {Resolvers, Zone}
    end.

-spec(find_custom_upstream(Labels :: [binary()]) ->
     {[upstream()] | internal, [binary()]}).
find_custom_upstream(QueryLabels) ->
    ForwardZones = dcos_dns_config:forward_zones(),
    UpstreamFilter = upstream_filter_fun(QueryLabels),
    maps:fold(UpstreamFilter, {[], []}, ForwardZones).

-spec(upstream_filter_fun([dns:labels()]) ->
    fun(([dns:labels()], upstream(), [upstream()]) ->
        {[upstream()] | internal, [binary()]})).
upstream_filter_fun(QueryLabels) ->
    fun(ZoneLabels, Upstream, Acc) ->
        case lists:prefix(ZoneLabels, QueryLabels) of
            true ->
                {Upstream, ZoneLabels};
            false ->
                Acc
        end
    end.

-spec(cluster_crypto_id() -> binary() | false).
cluster_crypto_id() ->
    case dcos_dns_key_mgr:keys() of
        false ->
            false;
        #{public_key := PublicKey} ->
            zbase32:encode(PublicKey)
    end.
