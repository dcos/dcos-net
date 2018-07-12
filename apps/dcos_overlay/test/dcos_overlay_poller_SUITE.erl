-module(dcos_overlay_poller_SUITE).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    unique_iprules_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("gen_netlink/include/netlink.hrl").

init_per_suite(Config) ->
    case string:strip(os:cmd("id -u"), right, $\n) of
        "0" -> Config;
        _ -> {skip, "Not running as root"}
    end.

end_per_suite(Config) ->
    Config.

all() ->
    [unique_iprules_test].

init_per_testcase(TestCaseName, Config) ->
    ct:pal("Starting Testcase: ~p", [TestCaseName]),
    meck:new(lashup_kv),
    meck:expect(lashup_kv, value, fun (_Key) ->
        []
    end),
    meck:expect(lashup_kv, request_op, fun (_Key, _Op) ->
        {ok, []}
    end),
    meck:new(httpc),
    meck:expect(httpc, request, fun(get, _, _, _) ->
        Node = <<"master1@nohost">>,
        Data = dcos_overlay_SUITE:create_data(Node),
        BinData = jiffy:encode(Data),
        {ok, {{"HTTP/1.1", 200, "OK"}, [], BinData}}
    end),
    Config.

end_per_testcase(_, _Config) ->
    meck:unload([httpc, lashup_kv]),
    os:cmd("ip link del vtep1024").

unique_iprules_test(_Config) ->
    Rules = start_get_kill_poller(),
    Rules = start_get_kill_poller(),
    ok.

start_get_kill_poller() ->
    maybe_kill_poller(),
    {ok, Pid} = dcos_overlay_poller:start_link(),
    {ok, NetlinkPid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    {ok, Rules} =
        try
            dcos_overlay_netlink:iprule_show(NetlinkPid, inet)
        after
            gen_netlink_client:stop(NetlinkPid),
            erlang:unregister(dcos_overlay_poller),
            erlang:unlink(Pid),
            erlang:exit(Pid, kill)
        end,
    ct:pal("Rules: ~p", [Rules]).

maybe_kill_poller() ->
    try
        Pid = whereis(dcos_overlay_poller),
        erlang:unregister(dcos_overlay_poller),
        erlang:unlink(Pid),
        erlang:exit(Pid, kill)
    catch _:_ ->
        ok
    end.
