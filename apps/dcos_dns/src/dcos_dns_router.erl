-module(dcos_dns_router).
-author("sdhillon").

-include("dcos_dns.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% API
-export([upstreams_from_questions/1]).

%% @doc Resolvers based on a set of "questions"
-spec(upstreams_from_questions(dns:questions()) -> [upstream()] | erldns).
upstreams_from_questions([#dns_query{name=Name}]) ->
    Labels = dcos_dns_app:parse_upstream_name(Name),
    find_upstream(Labels);
upstreams_from_questions([Question|Others]) ->
    %% There is more than one question. This is beyond our capabilities at the moment
    dcos_dns_metrics:update([dcos_dns, ignored_questions], length(Others), ?COUNTER),
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
-spec(find_upstream(Labels :: [binary()]) -> [upstream()] | erldns).
find_upstream([<<"mesos">>|_]) ->
    dcos_dns_config:mesos_resolvers();
find_upstream([<<"localhost">>|_]) ->
    erldns;
find_upstream([<<"zk">>|_]) ->
    erldns;
find_upstream([<<"spartan">>|_]) ->
    erldns;
find_upstream([<<"directory">>, <<"thisdcos">>|_]) ->
    erldns;
find_upstream([<<"global">>, <<"thisdcos">>|_]) ->
    erldns;
find_upstream([<<"directory">>, <<"dcos">>|_]) ->
    erldns;
find_upstream(Labels) ->
    case find_custom_upstream(Labels) of
        [] ->
            default_resolvers();
        Resolvers ->
            lager:debug("resolving ~p with custom upstream: ~p", [Labels, Resolvers]),
            Resolvers
    end.

-spec(find_custom_upstream(Labels :: [binary()]) -> [upstream()]).
find_custom_upstream(QueryLabels) ->
    ForwardZones = dcos_dns_config:forward_zones(),
    UpstreamFilter = upstream_filter_fun(QueryLabels),
    maps:fold(UpstreamFilter, [], ForwardZones).

-spec(upstream_filter_fun([dns:labels()]) ->
    fun(([dns:labels()], upstream(), [upstream()]) -> [upstream()])).
upstream_filter_fun(QueryLabels) ->
    fun(Labels, Upstream, Acc) ->
        case lists:prefix(Labels, QueryLabels) of
            true ->
                Upstream;
            false ->
                Acc
        end
    end.
