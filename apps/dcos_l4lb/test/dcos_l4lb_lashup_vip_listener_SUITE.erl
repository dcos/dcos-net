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

-define(LKEY(K), {{tcp, K, 80}, riak_dt_orswot}).
-define(LKEY(L, F), ?LKEY({name, {L, F}})).
-define(BE4, {{1, 2, 3, 4}, {{1, 2, 3, 4}, 80, 1}}).
-define(BE4OLD, {{1, 2, 3, 5}, {{1, 2, 3, 5}, 80}}).
-define(BE6, {{1, 2, 3, 4}, {{1, 0, 0, 0, 0, 0, 0, 1}, 80, 1}}).

lookup_vips(_Config) ->
    lashup_kv:request_op(?VIPS_KEY2, {update, [
        {update, ?LKEY({1, 2, 3, 4}), {add, ?BE4}},
        {update, ?LKEY({1, 2, 3, 5}), {add, ?BE4OLD}},
        {update, ?LKEY(<<"/foo">>, <<"bar">>), {add, ?BE4}},
        {update, ?LKEY(<<"/baz">>, <<"qux">>), {add, ?BE4}},
        {update, ?LKEY(<<"/qux">>, <<"ipv6">>), {add, ?BE6}}
    ]}),
    timer:sleep(100),
    {11, 0, 0, 37} = name2ip(<<"foo.bar">>),
    {11, 0, 0, 39} = IP4 = name2ip(<<"baz.qux">>),
    {16#fd01, 16#c, 0, 0, 16#6d6d, 16#9c64, 16#fd19, 16#f251} = IP6 =
        name2ip(?DNS_TYPE_AAAA, <<"qux.ipv6">>),

    lashup_kv:request_op(?VIPS_KEY2, {update, [
        {update, ?LKEY(<<"/foo">>, <<"bar">>), {remove, ?BE4}}
    ]}),
    timer:sleep(100),
    false = name2ip(<<"foo.bar">>),
    IP4 = name2ip(<<"baz.qux">>),
    IP6 = name2ip(?DNS_TYPE_AAAA, <<"qux.ipv6">>),

    lashup_kv:request_op(?VIPS_KEY2, {update, [
        {update, ?LKEY({1, 2, 3, 4}), {remove, ?BE4}},
        {update, ?LKEY({1, 2, 3, 5}), {remove, ?BE4OLD}},
        {update, ?LKEY(<<"/baz">>, <<"qux">>), {remove, ?BE4}},
        {update, ?LKEY(<<"/qux">>, <<"ipv6">>), {remove, ?BE6}}
    ]}),
    timer:sleep(100),
    false = name2ip(<<"foo.bar">>),
    false = name2ip(<<"baz.qux">>),
    false = name2ip(?DNS_TYPE_AAAA, <<"qux.ipv6">>).

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
