%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 22. Oct 2016 9:37 PM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_ipvs_SUITE).
-author("sdhillon").

-include_lib("common_test/include/ct.hrl").
-include("dcos_l4lb.hrl").

-export([
    all/0,
    init_per_testcase/2, end_per_testcase/2,
    test_v4/1, test_v6/1, test_normalize/1
]).

all() -> all(os:cmd("id -u"), os:getenv("CIRCLECI")).

%% root tests
all("0\n", false) ->
    [test_v4, test_v6, test_normalize];

%% non root tests
all(_, _) -> [].

init_per_testcase(_, Config) ->
    case os:cmd("ipvsadm -C") of
        "" ->
            AgentIP = {2, 2, 2, 2},
            os:cmd("ip link del minuteman"),
            os:cmd("ip link add minuteman type dummy"),
            os:cmd("ip link set minuteman up"),
            os:cmd("ip link del webserver"),
            os:cmd("ip link add webserver type dummy"),
            os:cmd("ip link set webserver up"),
            os:cmd(lists:flatten(io_lib:format(
                   "ip addr add ~s/32 dev webserver", [inet:ntoa(AgentIP)]))),
            os:cmd("ip addr add 1.1.1.1/32 dev webserver"),
            os:cmd("ip addr add 1.1.1.2/32 dev webserver"),
            os:cmd("ip addr add 1.1.1.3/32 dev webserver"),
            os:cmd("ip addr add fc01::1/128 dev webserver"),
            application:load(dcos_l4lb),
            application:set_env(dcos_l4lb, enable_networking, true),
            {ok, _} = application:ensure_all_started(inets),
            {ok, _} = application:ensure_all_started(dcos_l4lb),
            [{agentip, AgentIP} | Config];
        Result ->
            {skip, Result}
    end.

end_per_testcase(_, _Config) ->
    "" = os:cmd("ipvsadm -C"),
    os:cmd("ip link del minuteman"),
    os:cmd("ip link del webserver"),
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    ok.

make_v4_webserver(Idx) ->
    make_webserver(inet, {1, 1, 1, Idx}).

make_v6_webserver() ->
    make_webserver(inet6, {16#fc01, 16#0, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}).

make_webserver(Family, IP) ->
    file:make_dir("/tmp/htdocs"),
    {ok, Pid} = inets:start(httpd, [
        {port, 0},
        {server_name, "httpd_test"},
        {server_root, "/tmp"},
        {document_root, "/tmp/htdocs"},
        {ipfamily, Family},
        {bind_address, IP}
    ]),
    Pid.

%webservers() ->
%    lists:map(fun make_webserver/1, lists:seq(1,3)).

webserver(Pid, AgentIP) ->
    Info = httpd:info(Pid),
    Port = proplists:get_value(port, Info),
    IP = proplists:get_value(bind_address, Info),
    {AgentIP, {IP, Port}}.

add_webserver(VIP, WebServer) ->
    % inject an update for this vip
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{update, {VIP, riak_dt_orswot}, {add, WebServer}}]}).

remove_webserver(VIP, WebServer) ->
    % inject an update for this vip
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{update, {VIP, riak_dt_orswot}, {remove, WebServer}}]}).

remove_vip(VIP) ->
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{remove, {VIP, riak_dt_orswot}}]}).


test_vip(Family, VIP) ->
    %% Wait for lashup state to take effect
    timer:sleep(1000),
    test_vip(3, Family, VIP).

test_vip(0, _, _) ->
    error;
test_vip(Tries, Family, VIP = {tcp, IP0, Port}) ->
    IP1 = inet:ntoa(IP0),
    URI = uri(Family, IP1, Port),
    httpc:set_options([{ipfamily, Family}]),
    case httpc:request(get, {URI, _Headers = []}, [{timeout, 500}, {connect_timeout, 500}], []) of
        {ok, _} ->
            ok;
        {error, _} ->
            test_vip(Tries - 1, Family, VIP)
    end.

uri(inet, IP, Port) ->
    lists:flatten(io_lib:format("http://~s:~b/", [IP, Port]));
uri(inet6, IP, Port) ->
    lists:flatten(io_lib:format("http://[~s]:~b/", [IP, Port])).

test_v4(Config) ->
    AgentIP = ?config(agentip, Config),
    Family = inet,
    W1 = make_v4_webserver(1),
    W2 = make_v4_webserver(2),
    VIP = {tcp, {11, 0, 0, 1}, 8080},
    add_webserver(VIP, webserver(W1, AgentIP)),
    ok = test_vip(Family, VIP),
    remove_webserver(VIP, webserver(W1, AgentIP)),
    inets:stop(stand_alone, W1),
    add_webserver(VIP, webserver(W2, AgentIP)),
    ok = test_vip(Family, VIP),
    remove_webserver(VIP, webserver(W2, AgentIP)),
    error = test_vip(Family, VIP),
    remove_vip(VIP),
    error = test_vip(Family, VIP).

test_v6(Config) ->
    AgentIP = ?config(agentip, Config),
    Family = inet6,
    W = make_v6_webserver(),
    VIP = {tcp, {16#fd01, 16#0, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, 8080},
    add_webserver(VIP, webserver(W, AgentIP)),
    ok = test_vip(Family, VIP),
    remove_webserver(VIP, webserver(W, AgentIP)),
    error = test_vip(Family, VIP),
    remove_vip(VIP),
    error = test_vip(Family, VIP).

test_normalize(_Config) ->
    Normalized =
        normalize_services_and_dests({service(), [
            destination(<<10, 10, 0, 83, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>),
            destination(<<10, 10, 0, 248, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>),
            destination(<<10, 10, 0, 253, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>)
        ]}),
    Normalized =
        {{tcp, {11, 197, 245, 133}, 9042}, [
            {{10, 10, 0, 83}, 9042},
            {{10, 10, 0, 248}, 9042},
            {{10, 10, 0, 253}, 9042}
        ]}.

normalize_services_and_dests({Service0, Destinations0}) ->
    {AddressFamily, Service1} = dcos_l4lb_ipvs_mgr:service_address(Service0),
    Destinations1 = lists:map(
                      fun(Dest) ->
                          dcos_l4lb_ipvs_mgr:destination_address(AddressFamily, Dest)
                      end, Destinations0),
    Destinations2 = lists:usort(Destinations1),
    {Service1, Destinations2}.

service() ->
    [
        {address_family, 2},
        {protocol, 6},
        {address, <<11, 197, 245, 133, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
        {port, 9042},
        {sched_name, "wlc"},
        {flags, 2, 4294967295},
        {timeout, 0},
        {netmask, 4294967295},
        {stats, stats()}
    ].

destination(Address) ->
    [
        {address, Address},
        {port, 9042},
        {fwd_method, 0},
        {weight, 1},
        {u_threshold, 0},
        {l_threshold, 0},
        {active_conns, 0},
        {inact_conns, 0},
        {persist_conns, 0},
        {stats, stats()}
    ].

stats() ->
    [
        {conns, 0},
        {inpkts, 0},
        {outpkts, 0},
        {inbytes, 0},
        {outbytes, 0},
        {cps, 0},
        {inpps, 0},
        {outpps, 0},
        {inbps, 0},
        {outbps, 0}
    ].
