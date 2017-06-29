-module(dcos_dns_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ZkRecordServer = {dcos_dns_zk_record_server,
                      {dcos_dns_zk_record_server, start_link, []},
                       permanent, 5000, worker,
                       [dcos_dns_zk_record_server]},
    ConfigLoaderServer =
        #{
            id => dcos_dns_config_loader_server,
            start => {dcos_dns_config_loader_server, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [dcos_dns_config_loader_server]
        },

    WatchdogSup = #{
        id => dcos_dns_watchdog,
        start => {dcos_dns_watchdog, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [dcos_dns_watchdog]
    },

    KeyMgr = #{
        id => dcos_dns_key_mgr,
        start => {dcos_dns_key_mgr, start_link, []},
        restart => transient,
        modules => [dcos_dns_key_mgr],
        type => worker,
        shutdown => 5000
    },
    PollSrv = #{
        id => dcos_dns_poll_server,
        start => {dcos_dns_poll_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [dcos_dns_poll_server]
    },
    ListenerSrv = #{
        id => dcos_dns_listener,
        start => {dcos_dns_listener, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [dcos_dns_listener]
    },

    %% Configure metrics.
    dcos_dns_metrics:setup(),

    %% Setup ready.spartan zone / record
    ok = dcos_dns_zone_setup(),
    ok = localhost_zone_setup(),

    %% Systemd Sup intentionally goes last
    Children = [ZkRecordServer, ConfigLoaderServer, WatchdogSup, KeyMgr, PollSrv, ListenerSrv],
    Children1 = maybe_add_udp_servers(Children),

    sidejob:new_resource(
        dcos_dns_handler_fsm_sj, sidejob_supervisor,
        dcos_dns_config:handler_limit()),

    %% The top level sup should never die.
    {ok, { {one_for_all, 10000, 1}, Children1} }.

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
        start => {dcos_dns_udp_server, start_link, [Address]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [dcos_dns_udp_server]
    }.


localhost_zone_setup() ->
    Records = [
        #dns_rr{
            name = <<"localhost">>,
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
        },
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
    case catch erldns_zone_cache:put_zone({<<"localhost">>, Sha, Records}) of
        ok ->
            ok;
        Else ->
            {error, Else}
    end.

dcos_dns_zone_setup() ->
    Records = [
        #dns_rr{
            name = <<"spartan">>,
            type = ?DNS_TYPE_SOA,
            ttl = 5,
            data = #dns_rrdata_soa{
                mname = <<"ns.spartan">>, %% Nameserver
                rname = <<"support.mesosphere.com">>,
                serial = 0,
                refresh = 60,
                retry = 180,
                expire = 86400,
                minimum = 1
            }
        },
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
    case catch erldns_zone_cache:put_zone({<<"spartan">>, Sha, Records}) of
        ok ->
            ok;
        Else ->
            {error, Else}
    end.
