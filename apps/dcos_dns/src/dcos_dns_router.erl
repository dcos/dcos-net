-module(dcos_dns_router).
-author("sdhillon").

-include("dcos_dns.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% API
-export([upstreams_from_questions/1]).

%% @doc Resolvers based on a set of "questions"
-spec(upstreams_from_questions(dns:questions()) -> ordsets:ordset(upstream())).
upstreams_from_questions([#dns_query{name=Name}]) ->
    Labels = dcos_dns_app:parse_upstream_name(Name),
    Upstreams = find_upstream(Labels),
    lists:map(fun validate_upstream/1, Upstreams);

%% There is more than one question. This is beyond our capabilities at the moment
upstreams_from_questions([Question|Others]) ->
    dcos_dns_metrics:update([dcos_dns, ignored_questions], length(Others), ?COUNTER),
    upstreams_from_questions([Question]).

-spec(validate_upstream(upstream()) -> upstream()).
validate_upstream({{_, _, _, _}, Port} = Upstream) when is_integer(Port) ->
    Upstream.

%% This one is a little bit more complicated...
%% @private
-spec(erldns_resolvers() -> [upstream()]).
erldns_resolvers() ->
    ErlDNSServers = application:get_env(erldns, servers, []),
    retrieve_servers(ErlDNSServers, []).
retrieve_servers([], Acc) ->
    Acc;
retrieve_servers([Config|Rest], Acc) ->
    case {
            inet:parse_ipv4_address(proplists:get_value(address, Config, "")),
            proplists:get_value(port, Config),
            proplists:get_value(family, Config)
    } of
        {_, undefined, _} ->
            retrieve_servers(Rest, Acc);
        {{ok, Address}, Port, inet} when is_integer(Port) ->
            retrieve_servers(Rest, [{Address, Port}|Acc]);
        _ ->
            retrieve_servers(Rest, Acc)
    end.

%% @private
-spec(default_resolvers() -> [upstream()]).
default_resolvers() ->
    Defaults = [{{8, 8, 8, 8}, 53},
                {{4, 2, 2, 1}, 53},
                {{8, 8, 8, 8}, 53},
                {{4, 2, 2, 1}, 53},
                {{8, 8, 8, 8}, 53}],
    application:get_env(?APP, upstream_resolvers, Defaults).

%% @private
-spec(find_upstream(Labels :: [binary()]) -> [upstream()]).
find_upstream([<<"mesos">>|_]) ->
    dcos_dns_config:mesos_resolvers();
find_upstream([<<"localhost">>|_]) ->
    erldns_resolvers();
find_upstream([<<"zk">>|_]) ->
    erldns_resolvers();
find_upstream([<<"spartan">>|_]) ->
    erldns_resolvers();
find_upstream([<<"directory">>, <<"thisdcos">>|_]) ->
    erldns_resolvers();
find_upstream([<<"global">>, <<"thisdcos">>|_]) ->
    erldns_resolvers();
find_upstream([<<"directory">>, <<"dcos">>|_]) ->
    erldns_resolvers();
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
