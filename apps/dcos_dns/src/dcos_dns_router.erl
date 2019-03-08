-module(dcos_dns_router).
-author("sdhillon").

-include("dcos_dns.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% API
-export([upstreams_from_questions/1]).

%% @doc Resolvers based on a set of "questions"
-spec(upstreams_from_questions(dns:questions()) ->
    {[upstream()] | internal, binary()}).
upstreams_from_questions([#dns_query{name=Name}]) ->
    Labels = dcos_dns_app:parse_upstream_name(Name),
    find_upstream(Labels);
upstreams_from_questions([Question|Others]) ->
    %% There is more than one question. This is beyond our capabilities at the moment
    %% TODO replace it with a forwarder metrics
    Result = upstreams_from_questions([Question]),
    lager:debug("~p will be forwarded to ~p", [Others, Result]),
    Result.

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
    {[upstream()] | internal, binary()}).
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
find_upstream([<<"global">>, <<"thisdcos">>, Label |_]) ->
    {internal, <<Label/binary, ".thisdcos.global.">>};
find_upstream([<<"directory">>, <<"dcos">>, Id, Label |_]) ->
    {internal, <<Label/binary, ".", Id/binary, ".dcos.directory.">>};
find_upstream(Labels) ->
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
