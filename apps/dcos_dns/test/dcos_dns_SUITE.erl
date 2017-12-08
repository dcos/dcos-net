-module(dcos_dns_SUITE).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

%% common_test callbacks
-export([init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0]).

%% tests
-export([
         overload_test/1,
         multiple_query_test/1,
         upstream_test/1,
         mesos_test/1,
         zk_test/1,
         http_hosts_test/1,
         http_services_test/1,
         http_records_test/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").


-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-define(CONFIG, "../../../../config/sys.config").

%% ===================================================================
%% common_test callbacks
%% ===================================================================

init_per_suite(_Config) ->
    Workers = [
        dcos_dns_key_mgr,
        dcos_dns_poll_server,
        dcos_dns_listener
    ],
    meck_mods(Workers),
    {ok, _} = application:ensure_all_started(dcos_dns),
    {ok, _} = application:ensure_all_started(dcos_rest),
    meck:unload(Workers),
    generate_fixture_mesos_zone(),
    generate_thisdcos_directory_zone(),
    _Config.

end_per_suite(Config) ->
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    Config.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_, _Config) ->
    ok.

all() ->
    [
     upstream_test,
     mesos_test,
     zk_test,
     multiple_query_test,
     http_hosts_test,
     http_services_test,
     http_records_test,
     overload_test
    ].

meck_mods(Mods) when is_list(Mods) ->
    lists:foreach(fun meck_mods/1, Mods);
meck_mods(Mod) ->
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, start_link, fun () -> {ok, self()} end).

generate_fixture_mesos_zone() ->
    Records = [
        generate_soa_ns(<<"mesos">>),
        #dns_rr{
            name = <<"master.mesos">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
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
    ok = erldns_zone_cache:put_zone({<<"mesos">>, Sha, Records}).

generate_thisdcos_directory_zone() ->
    Records = [
        generate_soa_ns(<<"thisdcos.directory">>),
        generate_thisdcos_directory_records(),
        generate_thisdcos_directory_srv_records()
    ],
    Records0 = lists:flatten(Records),
    Sha = crypto:hash(sha, term_to_binary(Records0)),
    ok = erldns_zone_cache:put_zone({<<"thisdcos.directory">>, Sha, Records0}).

generate_thisdcos_directory_records() ->
    [
        #dns_rr{
            name = <<"commontest.thisdcos.directory">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
        },
        #dns_rr{
            name = <<"spartan">>,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ].

generate_thisdcos_directory_srv_records() ->
    [
        #dns_rr{
            name = <<"_service._tcp.commontest.thisdcos.directory">>,
            type = ?DNS_TYPE_SRV,
            ttl = 5,
            data = #dns_rrdata_srv{
                priority = 0,
                weight = 0,
                port = 1024,
                target = <<"commontest.thisdcos.directory">>
            }
        },
        #dns_rr{
            name = <<"_service._tcp.commontest.thisdcos.directory">>,
            type = ?DNS_TYPE_SRV,
            ttl = 5,
            data = #dns_rrdata_srv{
                priority = 0,
                weight = 0,
                port = 2048,
                target = <<"commontest.thisdcos.directory">>
            }
        }
    ].

generate_soa_ns(Name) ->
    #dns_rr{
        name = Name,
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
    }.

%% ===================================================================
%% tests
%% ===================================================================

%% @doc Assert an upstream request is resolved by the dual dispatch FSM.
upstream_test(_Config) ->
    {ok, DnsMsg} = inet_res:resolve("www.google.com", in, a, resolver_options()),
    Answers = inet_dns:msg(DnsMsg, anlist),
    ?assert(length(Answers) > 0),
    ok.

%% @doc Assert we can resolve Mesos records.
%%
%%      Shallow test; verifies that the mesos domain is parsed correctly
%%      and send to the dual dispatch FSM, but actual
%%      resolution bypasses the mesos servers, since they won't be
%%      there.  The external resolution test is covered via
%%      upstream_test/1.
%%
mesos_test(_Config) ->
    {ok, DnsMsg} = inet_res:resolve("master.mesos", in, a, resolver_options()),
    [Answer] = inet_dns:msg(DnsMsg, anlist),
    Data = inet_dns:rr(Answer, data),
    ?assertMatch({127, 0, 0, 1}, Data),
    ok.

%% @doc Assert we can resolve the Zookeeper records.
zk_test(_Config) ->
    gen_server:call(dcos_dns_zk_record_server, refresh),
    {ok, DnsMsg} = inet_res:resolve("zk-1.zk", in, a, resolver_options()),
    [Answer] = inet_dns:msg(DnsMsg, anlist),
    Data = inet_dns:rr(Answer, data),
    ?assertMatch({127, 0, 0, 1}, Data),
    ok.

multiple_query_test(_Config) ->
    Expected = "1.1.1.1\n2.2.2.2\n127.0.0.1\n",
    Command =
        "dig -p 8053 @127.0.0.1 +keepopen +tcp +short "
        "spartan1.testing.express "
        "spartan2.testing.express "
        "master.mesos",
    ?assertCmdOutput(Expected, Command).

overload_test(_Config) ->
    try
        ok = meck:new(dcos_dns_udp_server, [unstick, passthrough]),
        ok = meck:expect(
                dcos_dns_udp_server, do_reply,
                fun (From, Data) ->
                    timer:sleep(500),
                    catch meck:passthrough([From, Data])
                end),
        Pids = lists:map(fun spawn_link_resolve/1, lists:seq(0, 32)),
        Results = lists:map(fun (Pid) ->
            receive
                {done, Pid, Result} ->
                    Result
            after
                1000 ->
                    throw(timeout)
            end
        end, Pids),
        ?assertMatch([ok, timeout], lists:usort(Results))
    after
        ok = meck:unload(dcos_dns_udp_server)
    end.

spawn_link_resolve(_N) ->
    Parent = self(),
    proc_lib:spawn_link(fun () ->
        Host = "master.mesos",
        Opts = resolver_options(),
        Result =
            case inet_res:resolve(Host, in, a, Opts, 700) of
                {ok, _} -> ok;
                {error, timeout} -> timeout
            end,
        Parent ! {done, self(), Result}
    end).

%% @private
%% @doc Use the dcos_dns resolver.
resolver_options() ->
    LocalResolver = "127.0.0.1:8053",
    [{nameservers, [dcos_dns_app:parse_ipv4_address_with_port(LocalResolver, 53)]}].

http_hosts_test(_Config) ->
    Records = request("http://localhost:62080/v1/hosts/commontest.thisdcos.directory"),
    lists:foreach(fun (RR) ->
        ?assertMatch(
            {<<"host">>, <<"commontest.thisdcos.directory">>},
            lists:keyfind(<<"host">>, 1, RR)),
        {<<"ip">>, Ip} =
            lists:keyfind(<<"ip">>, 1, RR),
        ?assertMatch(
            {ok, _},
            inet:parse_address(binary_to_list(Ip)))
    end, Records).

http_services_test(_Config) ->
    Records = request("http://localhost:62080/v1/services/_service._tcp.commontest.thisdcos.directory"),
    lists:foreach(fun (RR) ->
        ?assertMatch(
            {<<"service">>, <<"_service._tcp.commontest.thisdcos.directory">>},
            lists:keyfind(<<"service">>, 1, RR)),
        ?assertMatch(
            {<<"host">>, <<"commontest.thisdcos.directory">>},
            lists:keyfind(<<"host">>, 1, RR)),
        ?assertMatch(
            {<<"ip">>, <<"127.0.0.1">>},
            lists:keyfind(<<"ip">>, 1, RR)),
        {<<"port">>, Port} = lists:keyfind(<<"port">>, 1, RR),
        ?assertMatch(true, lists:member(Port, [1024, 2048]))
    end, Records).

http_records_test(_Config) ->
    Records = request("http://localhost:62080/v1/records"),
    Records0 =
        lists:filter(fun (RR) ->
            {<<"name">>, Name} = lists:keyfind(<<"name">>, 1, RR),
            lists:member(Name, [<<"ready.spartan">>, <<"ns.spartan">>,
                                <<"ns.zk">>, <<"zk-1.zk">>, <<"localhost">>,
                                <<"commontest.thisdcos.directory">>,
                                <<"_service._tcp.commontest.thisdcos.directory">>])
        end, Records),
    ?assertMatch(8, length(Records0)).

request(Url) ->
    {ok, {_, _, Data}} =
        httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    jsx:decode(Data).
