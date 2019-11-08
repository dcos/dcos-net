-module(dcos_l4lb_lashup_vip_listener_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("dns/include/dns.hrl").
-include("dcos_l4lb.hrl").

-export([
    name2ip/1,
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2,
    lookup_vips/1
]).

name2ip(DName) ->
    name2ip(?DNS_TYPE_A, DName).

name2ip(DType, DName) ->
    case resolve(DType, <<DName/binary, ".l4lb.thisdcos.directory">>) of
        [#dns_rr{data=#dns_rrdata_a{ip = IP}}] -> IP;
        [#dns_rr{data=#dns_rrdata_aaaa{ip = IP}}] -> IP;
        [] -> false
    end.

all() ->
    [lookup_vips].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_, Config) ->
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    Config.

end_per_testcase(_, _Config) ->
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    dcos_l4lb_ipset_mgr:cleanup(),
    ok.

-define(KEY(K), {tcp, K, 80}).
-define(BE4, #{
    task_id => make_ref(),
    agent_ip => {1, 2, 3, 4},
    task_ip => [{1, 2, 3, 4}],
    port => 80,
    runtime => mesos
}).
-define(BE6, #{
    task_id => make_ref(),
    agent_ip => {1, 2, 3, 4},
    task_ip => [{1, 0, 0, 0, 0, 0, 0, 1}],
    port => 80,
    runtime => mesos
}).

lookup_vips(_Config) ->
    VIPs = #{
        ?KEY({1, 2, 3, 4}) => [?BE4],
        ?KEY({<<"/foo">>, <<"bar">>}) => [?BE4],
        ?KEY({<<"/baz">>, <<"qux">>}) => [?BE4],
        ?KEY({<<"/qux">>, <<"ipv6">>}) => [?BE6]
    },
    push_vips(VIPs),
    timer:sleep(100),
    {11, 0, 0, 37} = name2ip(<<"foo.bar">>),
    {11, 0, 0, 39} = IP4 = name2ip(<<"baz.qux">>),
    {16#fd01, 16#c, 0, 0, 16#6d6d, 16#9c64, 16#fd19, 16#f251} = IP6 =
        name2ip(?DNS_TYPE_AAAA, <<"qux.ipv6">>),

    VIPs0 = maps:remove(?KEY({<<"/foo">>, <<"bar">>}), VIPs),
    push_vips(VIPs0),
    timer:sleep(100),
    false = name2ip(<<"foo.bar">>),
    IP4 = name2ip(<<"baz.qux">>),
    IP6 = name2ip(?DNS_TYPE_AAAA, <<"qux.ipv6">>),

    push_vips(#{}),
    timer:sleep(100),
    false = name2ip(<<"foo.bar">>),
    false = name2ip(<<"baz.qux">>),
    false = name2ip(?DNS_TYPE_AAAA, <<"qux.ipv6">>).

push_vips(VIPs) ->
    Op = {assign, VIPs, erlang:system_time(millisecond)},
    {ok, _Info} = lashup_kv:request_op(
        ?VIPS_KEY3, {update, [{update, ?VIPS_FIELD, Op}]}).

-define(LOCALHOST, {127, 0, 0, 1}).
resolve(DType, DName) ->
    DNSQueries = [#dns_query{name=DName, type=DType}],
    DNSMessage = #dns_message{
        rd=true, qc=length(DNSQueries),
        questions=DNSQueries
    },
    #dns_message{answers=DNSAnswers} =
        erldns_handler:do_handle(DNSMessage, ?LOCALHOST),
    DNSAnswers.
