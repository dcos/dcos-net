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

    %% Systemd Sup intentionally goes last
    Children = [
        ?CHILD(dcos_dns_zk_record_server),
        ?CHILD(dcos_dns_config_loader_server),
        ?CHILD(dcos_dns_key_mgr, #{restart => transient}),
        ?CHILD(dcos_dns_poll_server),
        ?CHILD(dcos_dns_listener)
    ],
    Children1 = maybe_add_udp_servers(Children),

    sidejob:new_resource(
        dcos_dns_handler_fsm_sj, sidejob_supervisor,
        dcos_dns_config:handler_limit()),

    %% The top level sup should never die.
    {ok, {#{strategy => one_for_all, intensity => 10000, period => 1}, Children1}}.

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

localhost_zone_setup() ->
    Records = [
        soa_record(<<"localhost">>),
        #dns_rr{
            name = <<"localhost">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
        },
        #dns_rr{
            name = <<"localhost">>,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    erldns_zone_cache:put_zone({<<"localhost">>, Sha, Records}).

dcos_dns_zone_setup() ->
    Records = [
        soa_record(<<"spartan">>),
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
        },
        #dns_rr{
            name = <<"spartan">>,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    erldns_zone_cache:put_zone({<<"spartan">>, Sha, Records}).
