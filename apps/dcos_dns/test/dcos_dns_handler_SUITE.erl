-module(dcos_dns_handler_SUITE).

-include_lib("dns/include/dns.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-export([
    init_per_suite/1,
    end_per_suite/1,
    all/0,
    groups/0
]).

-export([
    udp_ready/1,
    tcp_ready/1,
    keep_tcp_ready/1,

    udp_basic_upstream/1,
    tcp_basic_upstream/1,
    multi_upstreams/1,
    mixed_upstreams/1,
    no_upstream/1,
    broken_upstreams/1,

    add_thisnode/1,

    tcp_fallback/1,
    overload/1,

    registry/1,
    cnames/1,

    rr_loadbalance/1,
    random_loadbalance/1,
    none_loadbalance/1,
    cnames_loadbalance/1,

    l4lb_rename/1,
    dcos_rename/1
]).

init_per_suite(Config) ->
    {ok, Apps} = application:ensure_all_started(dcos_dns),
    {ok, _} = lashup_kv:request_op([navstar, key], {update, [
        {update, {public_key, riak_dt_lwwreg}, {assign, <<"foobar">>}},
        {update, {secret_key, riak_dt_lwwreg}, {assign, <<"barqux">>}}
    ]}),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    lists:foreach(fun (App) ->
        ok = application:stop(App),
        ok = application:unload(App)
    end, ?config(apps, Config)).

all() ->
    [
        {group, ready},
        {group, upstream},
        {group, thisnode},
        {group, dcos},
        {group, component},
        {group, loadbalance},
        {group, rename}
    ].

groups() ->
    [
        {ready, [], [udp_ready, tcp_ready, keep_tcp_ready]},
        {upstream, [], [
            udp_basic_upstream, tcp_basic_upstream, multi_upstreams,
            mixed_upstreams, no_upstream, broken_upstreams
        ]},
        {thisnode, [], [add_thisnode]},
        {dcos, [], [tcp_fallback, overload]},
        {component, [], [registry, cnames]},
        {loadbalance, [], [
            rr_loadbalance, random_loadbalance,
            none_loadbalance, cnames_loadbalance
        ]},
        {rename, [], [l4lb_rename, dcos_rename]}
    ].

%%%===================================================================
%%% Ready tests
%%%===================================================================

ready(_Config, Opts) ->
    {ok, Msg} = resolve("ready.spartan", in, a, Opts),
    [RR] = inet_dns:msg(Msg, anlist),
    ?assertEqual({127, 0, 0, 1}, inet_dns:rr(RR, data)).

udp_ready(Config) ->
    ready(Config, []).

tcp_ready(Config) ->
    ready(Config, [nousevc]).

keep_tcp_ready(_Config) ->
    Timeout = 1000,
    {IP, Port} = nameserver(),
    Opts = [{active, true}, binary, {packet, 2}, {send_timeout, Timeout}],
    {ok, Sock} = gen_tcp:connect(IP, Port, Opts),
    ok = keep_tcp_ready_loop(Sock, 3, Timeout),
    gen_tcp:close(Sock).

keep_tcp_ready_loop(_Sock, 0, _Timeout) ->
    ok;
keep_tcp_ready_loop(Sock, N, Timeout) ->
    Request =
        dns:encode_message(
            #dns_message{
                qc = 1,
                questions = [#dns_query{
                    name = <<"ready.spartan">>,
                    class = ?DNS_CLASS_IN,
                    type = ?DNS_TYPE_A
                }]
            }),
    ok = gen_tcp:send(Sock, Request),
    receive
        {tcp, Sock, Data} ->
            ?assertMatch(
                #dns_message{answers = [#dns_rr{}]},
                dns:decode_message(Data))
    after Timeout ->
        exit(Timeout)
    end,
    keep_tcp_ready_loop(Sock, N - 1, Timeout).

%%%===================================================================
%%% Upstream tests
%%%===================================================================

basic_upstream(_Config, Opts) ->
    ok = application:set_env(dcos_dns, upstream_resolvers, [
        {{1, 1, 1, 1}, 53},
        {{1, 0, 0, 1}, 53}
    ]),
    {ok, Msg} = resolve("dcos.io", in, a, Opts),
    RRs = inet_dns:msg(Msg, anlist),
    ?assertNotEqual([], RRs).

udp_basic_upstream(Config) ->
    basic_upstream(Config, []).

tcp_basic_upstream(Config) ->
    basic_upstream(Config, [nousevc]).

multi_upstreams(_Config) ->
    ok = application:set_env(dcos_dns, upstream_resolvers, [
        {{1, 1, 1, 1}, 53},
        {{1, 0, 0, 1}, 53},
        {{8, 4, 4, 8}, 53},
        {{8, 8, 8, 8}, 53}
    ]),
    upstream_resolve("dcos.io").

mixed_upstreams(_Config) ->
    ok = application:set_env(dcos_dns, upstream_resolvers, [
        {{1, 1, 1, 1}, 53},
        {{1, 0, 0, 1}, 53},
        {{127, 0, 0, 1}, 65535}
    ]),
    upstream_resolve("dcos.io").

no_upstream(_Config) ->
    ok = application:set_env(dcos_dns, upstream_resolvers, []),
    ?assertEqual(
        {ok, [<<";; Warning: query response not set">>]},
        dig(["dcos.io"])).

broken_upstreams(_Config) ->
    ok = application:set_env(dcos_dns, upstream_resolvers, [
        {{127, 0, 0, 1}, 65535},
        {{127, 0, 0, 2}, 65535}
    ]),
    ?assertEqual(
        {ok, [<<";; Warning: query response not set">>]},
        dig(["dcos.io"])).

upstream_resolve(Name) ->
    lists:foreach(fun (_) ->
        {ok, Msg} = resolve(Name, in, a, []),
        RRs = inet_dns:msg(Msg, anlist),
        ?assertNotEqual([], RRs)
    end, lists:seq(1, 8)).

%%%===================================================================
%%% Thisnode functions
%%%===================================================================

add_thisnode(_Config) ->
    Name = <<"thisnode.thisdcos.directory">>,
    Addr = {127, 0, 0, 1},

    ok = dcos_dns:push_zone(Name, []),
    {ok, Msg0} = resolve(Name, in, a, []),
    ?assertEqual([], inet_dns:msg(Msg0, anlist)),

    ok = dcos_dns:push_zone(Name, [
        dcos_dns:dns_record(Name, Addr)
    ]),
    {ok, Msg} = resolve(Name, in, a, []),
    [RR] = inet_dns:msg(Msg, anlist),
    ?assertEqual(Addr, inet_dns:rr(RR, data)).

%%%===================================================================
%%% DC/OS functions
%%%===================================================================

tcp_fallback(_Config) ->
    ZoneName = <<"dcos.thisdcos.directory">>,
    AppName = <<"app.autoip.", ZoneName/binary>>,
    IPs = [{127, 0, 0, X} || X <- lists:seq(1, 128)],
    ok = dcos_dns:push_zone(ZoneName, dcos_dns:dns_records(AppName, IPs)),
    {ok, Output} = dig([AppName]),
    ?assertEqual(length(IPs), length(Output)).

overload(_Config) ->
    ZoneName = <<"dcos.thisdcos.directory">>,
    AppName = <<"app.autoip.", ZoneName/binary>>,
    IPs = [{127, 0, 0, X} || X <- lists:seq(1, 255)],
    ok = dcos_dns:push_zone(ZoneName, dcos_dns:dns_records(AppName, IPs)),
    Parent = self(),
    Queries = 4 * dcos_dns_handler_sj:limit(),
    lists:foreach(fun (Seq) ->
        proc_lib:spawn_link(fun () ->
            overload_worker(Seq, Parent, AppName)
        end)
    end, lists:seq(1, Queries)),
    Results = [ receive {Seq, R} -> R end || Seq <- lists:seq(1, Queries) ],
    ?assertEqual([ok, overload], lists:usort(Results)).

overload_worker(Seq, Parent, AppName) ->
    Query = #dns_query{
        name = AppName,
        class = ?DNS_CLASS_IN,
        type = ?DNS_TYPE_A
    },
    Msg = #dns_message{qc = 1, questions = [Query]},
    Request = dns:encode_message(Msg),
    ReplyFun =
        fun (_Bin) ->
            Parent ! {Seq, ok},
            timer:sleep(1000)
        end,
    case dcos_dns_handler:start(tcp, Request, ReplyFun) of
        {ok, _Pid} ->
            ok;
        {error, Error} ->
            Parent ! {Seq, Error}
    end.

%%%===================================================================
%%% Component functions
%%%===================================================================

registry(_Config) ->
    IPs = [{127, 0, 0, X} || X <- lists:seq(1, 5)],
    MesosRRs = dcos_dns:dns_records(<<"master.mesos.thisdcos.directory">>, IPs),
    ok = dcos_dns:push_zone(<<"mesos.thisdcos.directory">>, MesosRRs),
    ok = dcos_dns:push_zone(<<"component.thisdcos.directory">>, [
        dcos_dns:cname_record(
            <<"registry.component.thisdcos.directory">>,
            <<"master.mesos.thisdcos.directory">>)
    ]),
    {ok, Msg} = resolve("registry.component.thisdcos.directory", in, a, []),
    [CNameRR | RRs] = inet_dns:msg(Msg, anlist),
    ?assertMatch(#{
        type := cname,
        domain := "registry.component.thisdcos.directory",
        data := "master.mesos.thisdcos.directory"
    }, maps:from_list(inet_dns:rr(CNameRR))),
    ?assertEqual(IPs, lists:sort([inet_dns:rr(RR, data) || RR <- RRs])).

cnames(_Config) ->
    cnames_init_test_zone(),
    {ok, Msg} = resolve("foo.test.thisdcos.directory", in, a, []),
    % NOTE: CNAME records must appear before A/AAAA records,
    % the order of CNAME records does also matter.
    RRs = inet_dns:msg(Msg, anlist),
    ?assertMatch([
        #{
            type := cname,
            domain := "foo.test.thisdcos.directory",
            data := "bar.test.thisdcos.directory"
        }, #{
            type := cname,
            domain := "bar.test.thisdcos.directory",
            data := "baz.test.thisdcos.directory"
        }, #{
            type := cname,
            domain := "baz.test.thisdcos.directory",
            data := "qux.test.thisdcos.directory"
        } | _
    ], [maps:from_list(inet_dns:rr(RR)) || RR <- RRs]),
    ?assertEqual(8, length(RRs)).

cnames_init_test_zone() ->
    ok = dcos_dns:push_zone(<<"test.thisdcos.directory">>, [
        dcos_dns:cname_record(
            <<"foo.test.thisdcos.directory">>,
            <<"bar.test.thisdcos.directory">>),
        dcos_dns:cname_record(
            <<"bar.test.thisdcos.directory">>,
            <<"baz.test.thisdcos.directory">>),
        dcos_dns:cname_record(
            <<"baz.test.thisdcos.directory">>,
            <<"qux.test.thisdcos.directory">>) |
        dcos_dns:dns_records(
            <<"qux.test.thisdcos.directory">>,
            [{127, 0, 0, X} || X <- lists:seq(1, 5)])
    ]).

%%%===================================================================
%%% Load Balance functions
%%%===================================================================

rr_loadbalance(Config) ->
    ok = application:set_env(dcos_dns, loadbalance, round_robin),
    Results = loadbalance(Config),
    ?assert(length(lists:usort(Results)) > length(hd(Results)) / 2),
    ?assertMatch([_], lists:usort([lists:sort(R) || R <- Results])).

random_loadbalance(Config) ->
    ok = application:set_env(dcos_dns, loadbalance, random),
    Results = loadbalance(Config),
    ?assert(length(lists:usort(Results)) > length(Results) / 2),
    ?assertMatch([_], lists:usort([lists:sort(R) || R <- Results])).

none_loadbalance(Config) ->
    ok = application:set_env(dcos_dns, loadbalance, disabled),
    Results = loadbalance(Config),
    ?assertMatch([_], lists:usort(Results)).

loadbalance(_Config) ->
    ZoneName = <<"mesos.thisdcos.directory">>,
    AppName = <<"app.autoip.", ZoneName/binary>>,
    IPs = [{127, 0, 0, X} || X <- lists:seq(1, 16)],
    ok = dcos_dns:push_zone(ZoneName, dcos_dns:dns_records(AppName, IPs)),
    lists:map(fun (_) ->
        {ok, Msg} = resolve(AppName, in, a, []),
        [ inet_dns:rr(RR, data) || RR <- inet_dns:msg(Msg, anlist) ]
    end, lists:seq(1, 128)).

cnames_loadbalance(Config) ->
    ok = application:set_env(dcos_dns, loadbalance, round_robin),
    cnames(Config),
    ok = application:set_env(dcos_dns, loadbalance, random),
    cnames(Config),
    ok = application:set_env(dcos_dns, loadbalance, disabled),
    cnames(Config).

%%%===================================================================
%%% Rename functions
%%%===================================================================

l4lb_rename(_Config) ->
    Name = <<"app.marathon">>,
    Addr = {127, 0, 0, 1},
    Zones = [
        <<"l4lb.thisdcos.directory">>,
        <<"l4lb.thisdcos.global">>,
        <<"dclb.thisdcos.directory">>,
        <<"dclb.thisdcos.global">>
    ],
    Zone = hd(Zones),

    ok = dcos_dns:push_zone(Zone, []),
    lists:foreach(fun (Z) ->
        FQDN = binary_to_list(<<Name/binary, $., Z/binary>>),
        {error, {nxdomain, _Msg}} = resolve(FQDN, in, a, [])
    end, Zones),

    ok = dcos_dns:push_zone(Zone, [
        dcos_dns:dns_record(<<Name/binary, $., Zone/binary>>, Addr)
    ]),
    lists:foreach(fun (Z) ->
        FQDN = binary_to_list(<<Name/binary, $., Z/binary>>),
        {ok, Msg} = resolve(FQDN, in, a, []),
        [RR] = inet_dns:msg(Msg, anlist),
        ?assertEqual(FQDN, inet_dns:rr(RR, domain)),
        ?assertEqual(Addr, inet_dns:rr(RR, data))
    end, Zones).

dcos_rename(_Config) ->
    ZoneName = <<"dcos.thisdcos.directory">>,
    AppName = <<"app.autoip.", ZoneName/binary>>,
    IPs = [{127, 0, 0, X} || X <- lists:seq(1, 5)],
    ok = dcos_dns:push_zone(ZoneName, dcos_dns:dns_records(AppName, IPs)),

    {ok, Msg} = resolve(AppName, in, a, []),
    ?assertEqual(5, length(inet_dns:msg(Msg, anlist))),
    RRs = [inet_dns:rr(RR, domain) || RR <- inet_dns:msg(Msg, anlist)],
    ?assertEqual([binary_to_list(AppName)], lists:usort(RRs)),

    #{public_key := Pk} = dcos_dns_key_mgr:keys(),
    CryptoId = zbase32:encode(Pk),

    ReName = <<"app.autoip.dcos.", CryptoId/binary, ".dcos.directory">>,
    {ok, ReMsg} = resolve(ReName, in, a, []),
    ?assertEqual(5, length(inet_dns:msg(ReMsg, anlist))),
    ReRRs = [inet_dns:rr(RR, domain) || RR <- inet_dns:msg(ReMsg, anlist)],
    ?assertEqual([binary_to_list(ReName)], lists:usort(ReRRs)).

%%%===================================================================
%%% Internal functions
%%%===================================================================

dig(Args) ->
    {IP, Port} = nameserver(),
    PortStr = integer_to_list(Port),
    Command = ["/usr/bin/dig", "-p", PortStr, "@" ++ inet:ntoa(IP), "+short"],
    case dcos_net_utils:system(Command ++ Args, 30000) of
        {ok, Output} ->
            Lines = binary:split(Output, <<"\n">>, [global]),
            {ok, [ L || L <- Lines, L =/= <<>> ]};
        {error, {exit_status, 1}} ->
            {error, usage_error};
        {error, {exit_status, 8}} ->
            {error, batch_file};
        {error, {exit_status, 9}} ->
            {error, no_reply};
        {error, {exit_status, 10}} ->
            {error, internal};
        {error, Error} ->
            {error, Error}
    end.

nameserver() ->
    {ok, Port} = application:get_env(dcos_dns, udp_port),
    {ok, Port} = application:get_env(dcos_dns, tcp_port),
    {{127, 0, 0, 1}, Port}.

resolve(Name, Class, Type, Opts) when is_binary(Name) ->
    resolve(binary_to_list(Name), Class, Type, Opts);
resolve(Name, Class, Type, Opts) ->
    Opts0 = [{nameservers, [nameserver()]} | Opts],
    inet_res:resolve(Name, Class, Type, Opts0).
