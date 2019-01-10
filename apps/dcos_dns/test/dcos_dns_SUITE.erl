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
         http_records_test/1,
         dns_cache_test/1
        ]).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% common_test callbacks
%% ===================================================================

init_per_suite(Config) ->
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
    Config.

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
     overload_test,
     dns_cache_test
    ].

meck_mods(Mods) when is_list(Mods) ->
    lists:foreach(fun meck_mods/1, Mods);
meck_mods(Mod) ->
    meck:new(Mod, [non_strict]),
    meck:expect(Mod, start_link, fun () -> {ok, self()} end).

generate_fixture_mesos_zone() ->
    ok = dcos_dns:push_zone(
        <<"mesos">>,
        [dcos_dns:dns_record(<<"master.mesos">>, {127, 0, 0, 1})]).

generate_thisdcos_directory_zone() ->
    ok = dcos_dns:push_zone(
        <<"thisdcos.directory">>,
        [
            dcos_dns:dns_record(
                <<"commontest.thisdcos.directory">>,
                {127, 0, 0, 1}),
            dcos_dns:srv_record(
                <<"_service._tcp.commontest.thisdcos.directory">>,
                {<<"commontest.thisdcos.directory">>, 1024}),
            dcos_dns:srv_record(
                <<"_service._tcp.commontest.thisdcos.directory">>,
                {<<"commontest.thisdcos.directory">>, 2048})
        ]).

%% ===================================================================
%% tests
%% ===================================================================

%% @doc Assert an upstream request is resolved by the dual dispatch FSM.
upstream_test(_Config) ->
    {ok, DnsMsg} = inet_res:resolve("www.google.com", in, a, resolver_options()),
    Answers = inet_dns:msg(DnsMsg, anlist),
    ?assert(length(Answers) > 0).

%% @doc Assert we can resolve Mesos records.
%%
%%      Shallow test; verifies that the mesos domain is parsed correctly
%%      and send to the dual dispatch FSM, but actual
%%      resolution bypasses the mesos servers, since they won't be
%%      there.  The external resolution test is covered via
%%      upstream_test/1.
%%
mesos_test(_Config) ->
    ?assertMatch({127, 0, 0, 1}, resolve("master.mesos")).

%% @doc Assert we can resolve the Zookeeper records.
zk_test(_Config) ->
    gen_server:call(dcos_dns_zk_record_server, refresh),
    ?assertMatch({127, 0, 0, 1}, resolve("zk-1.zk")).

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
        ok = meck:new(gen_udp, [unstick, passthrough]),
        ok = meck:expect(gen_udp, send,
                fun (Socket, IP, Port, Data) ->
                    Timeout =
                        case Port of 8053 -> 0; 62053 -> 0; Port -> 200 end,
                    timer:sleep(Timeout),
                    catch meck:passthrough([Socket, IP, Port, Data])
                end),
        Pids = lists:map(fun spawn_link_resolve/1, lists:seq(0, 32)),
        Results = lists:map(fun (Pid) ->
            receive
                {done, Pid, Result} ->
                    Result
            after
                5000 ->
                    throw(timeout)
            end
        end, Pids),
        ?assertMatch([ok, timeout], lists:usort(Results))
    after
        ok = meck:unload(gen_udp)
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
    ?assertMatch(7, length(Records0)).

%% @doc Assert if we can read newly added record
dns_cache_test(_Config) ->
    Name = "myapp.commontest.thisdcos.directory",
    ?assertError(_, resolve(Name)),
    add_record(Name),
    ?assertMatch({127, 0, 0, 1}, resolve(Name)).

add_record(Name) ->
    dcos_dns:push_zone(
        <<"thisdcos.directory">>,
        [dcos_dns:dns_record(list_to_binary(Name), {127, 0, 0, 1})]).

resolve(Name) ->
    {ok, DnsMsg} = inet_res:resolve(Name, in, a, resolver_options()),
    [Answer] = inet_dns:msg(DnsMsg, anlist),
    inet_dns:rr(Answer, data).

request(Url) ->
    {ok, {_, _, Data}} =
        httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    jsx:decode(Data).
