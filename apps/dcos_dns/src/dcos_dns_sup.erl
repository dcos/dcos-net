-module(dcos_dns_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-define(CHILD(Module), #{id => Module, start => {Module, start_link, []}}).
-define(CHILD(Module, Custom), maps:merge(?CHILD(Module), Custom)).

start_link(Enabled) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Enabled]).

init([false]) ->
    {ok, {#{}, []}};
init([true]) ->
    %% Configure metrics.
    dcos_dns_metrics:setup(),

    %% Setup ready.spartan zone / record
    ok = dcos_dns_zone_setup(),
    ok = localhost_zone_setup(),
    ok = custom_zones_setup(),

    %% Systemd Sup intentionally goes last
    Children = [
        ?CHILD(dcos_dns_zk_record_server),
        ?CHILD(dcos_dns_config_loader_server),
        ?CHILD(dcos_dns_key_mgr, #{restart => transient}),
        ?CHILD(dcos_dns_listener)
    ],
    Children1 = maybe_add_udp_servers(Children),

    IsMaster = dcos_net_app:is_master(),
    MChildren =
        [?CHILD(dcos_dns_mesos_dns) || IsMaster] ++
        [?CHILD(dcos_dns_mesos) || IsMaster],

    sidejob:new_resource(
        dcos_dns_handler_sj, sidejob_supervisor,
        dcos_dns_config:handler_limit()),

    %% The top level sup should never die.
    {ok, {#{intensity => 10000, period => 1},
        MChildren ++ Children1
    }}.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
maybe_add_udp_servers(Children) ->
    case dcos_dns_config:udp_enabled() of
        true ->
            udp_servers() ++ Children;
        false ->
            Children
    end.

udp_servers() ->
    Addresses = dcos_dns_config:bind_ips(),
    lists:map(fun udp_server/1, Addresses).

udp_server(Address) ->
    #{
        id => {dcos_dns_udp_server, Address},
        start => {dcos_dns_udp_server, start_link, [Address]}
    }.


soa_record(Name) ->
    #dns_rr{
        name = Name,
        type = ?DNS_TYPE_SOA,
        ttl = 5,
        data = #dns_rrdata_soa{
            mname = <<"ns.spartan">>, %% Nameserver
            rname = <<"support.mesosphere.com">>,
            serial = 1,
            refresh = 60,
            retry = 180,
            expire = 86400,
            minimum = 1
        }
    }.

ns_record(Name) ->
    #dns_rr{
        name = Name,
        type = ?DNS_TYPE_NS,
        ttl = 3600,
        data = #dns_rrdata_ns{
            dname = <<"ns.spartan">>
        }
    }.

localhost_zone_setup() ->
    Records = [
        soa_record(<<"localhost">>),
        ns_record(<<"localhost">>),
        #dns_rr{
            name = <<"localhost">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
        }
    ],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    erldns_zone_cache:put_zone({<<"localhost">>, Sha, Records}).

dcos_dns_zone_setup() ->
    Records = [
        soa_record(<<"spartan">>),
        ns_record(<<"spartan">>),
        #dns_rr{
            name = <<"ready.spartan">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
        },
        #dns_rr{
            name = <<"ns.spartan">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{
                ip = {198, 51, 100, 1} %% Default dcos_dns IP
            }
        }
    ],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    erldns_zone_cache:put_zone({<<"spartan">>, Sha, Records}).

custom_zones_setup() ->
    Zones = application:get_env(dcos_dns, zones, #{}),
    maps:fold(fun (ZoneName, Zone, ok) ->
        ZoneName0 = to_binary(ZoneName),
        true = validate_zone_name(ZoneName0),
        Records = [
            soa_record(ZoneName0),
            ns_record(ZoneName0) |
            lists:map(fun (R) -> record(ZoneName0, R) end, Zone)
        ],
        Sha = crypto:hash(sha, term_to_binary(Records)),
        erldns_zone_cache:put_zone({ZoneName0, Sha, Records})
    end, ok, Zones).

-spec validate_zone_name(ZoneName :: binary()) -> boolean().
validate_zone_name(ZoneName) ->
    case dcos_dns_app:parse_upstream_name(ZoneName) of
        [<<"directory">>, <<"thisdcos">>, <<"l4lb">>  | _Labels] -> false;
        [<<"directory">>, <<"thisdcos">>, <<"mesos">> | _Labels] -> false;
        [<<"directory">>, <<"thisdcos">>, <<"dcos">>  | _Labels] -> false;
        [<<"directory">>, <<"thisdcos">>, _Zone | _Labels] -> true;
        _Labels -> false
    end.

-spec record(ZoneName :: binary(), Record :: maps:map()) -> dns:rr().
record(ZoneName, #{type := cname, name := CName, value := DName}) ->
    CName0 = list_to_binary(mesos_state:label(CName)),
    #dns_rr{
        name = <<CName0/binary, ".", ZoneName/binary>>,
        type = ?DNS_TYPE_CNAME,
        ttl = 5,
        data = #dns_rrdata_cname{dname=to_binary(DName)}
    };
record(_ZoneName, Record) ->
    lager:error("Unexpected format: ~p", [Record]),
    init:stop(1),
    error(stop).

-spec to_binary(term()) -> binary().
to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(List) when is_list(List) ->
    list_to_binary(List).
