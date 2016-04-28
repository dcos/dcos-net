-module(dcos_dns_sup).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-include("dcos_dns.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
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

    HandlerSup = #{
        id => dcos_dns_handler_sup,
        start => {dcos_dns_handler_sup, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => supervisor,
        modules => [dcos_dns_handler_sup]
    },

    WatchdogSup = #{
        id => dcos_dns_watchdog,
        start => {dcos_dns_watchdog, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [dcos_dns_watchdog]
    },
    %% Configure metrics.
    dcos_dns_metrics:setup(),

    %% Setup ready.spartan zone / record
    ok = dcos_dns_zone_setup(),

    %% Systemd Sup intentionally goes last
    Children = [HandlerSup, ZkRecordServer, ConfigLoaderServer, WatchdogSup],
    Children1 = maybe_add_udp_servers(Children),

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
    Addresses = dcos_dns_app:bind_ips(),
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

dcos_dns_zone_setup() ->
    SOA = #dns_rr{
        name = <<"spartan">>,
        type = ?DNS_TYPE_SOA,
        ttl = 5
    },
    RR = #dns_rr{
        name = <<"ready.spartan">>,
        type = ?DNS_TYPE_A,
        ttl = 5,
        data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
    },
    Records = [SOA, RR],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    case catch erldns_zone_cache:put_zone({<<"spartan">>, Sha, Records}) of
        ok ->
            ok;
        Else ->
            {error, Else}
    end.