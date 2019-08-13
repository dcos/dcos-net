-module(dcos_l4lb_ipset_SUITE).
-export([
    all/0,
    init_per_testcase/2, end_per_testcase/2,
    test_huge/1
]).

-include_lib("eunit/include/eunit.hrl").

all() ->
    [test_huge].

init_per_testcase(TestCase, Config) ->
    Uid = list_to_integer(string:strip(os:cmd("id -u"), right, $\n)),
    init_per_testcase(Uid, TestCase, Config).

init_per_testcase(0, _TestCase, Config) ->
    Config;
init_per_testcase(_, _, _) ->
    {skip, "Not running as root"}.

end_per_testcase(_, _Config) ->
    dcos_l4lb_ipset_mgr:cleanup().

test_huge(_Config) ->
    % NOTE: it's not a performance test, ipset netlink protocol split a big
    % hash into several netlink messages. The test checks that the ipset
    % manager can handle this case.

    % Generating 32768 entries.
    Range = lists:seq(1, 8),
    IPs = [{A, B, C, D} || A <- Range, B <- Range, C <- Range, D <- Range],
    Entries = [{tcp, IP, Port} || IP <- IPs, Port <- Range],

    % Starting the ipset manager.
    {ok, Pid} = dcos_l4lb_ipset_mgr:start_link(),

    % Adding entries.
    ok = add_entries(Pid, Entries),
    ?assertEqual(
        lists:sort(Entries),
        lists:sort(get_entries(Pid))),

    % Removing entries.
    ok = remove_entries(Pid, Entries),
    ?assertEqual([], get_entries(Pid)),

    % Stopping the ipset manager.
    unlink(Pid),
    exit(Pid, kill).

%%%===================================================================
%%% Call functions
%%%===================================================================

% NOTE: On slow CI nodes, it can take a bit longer than default 5 seconds to
% add, remove, or get ipset entries. So for test purposes, here are functions
% that don't have timeouts. The functions don't require prometheus running.

get_entries(Pid) ->
    gen_server:call(Pid, get_entries, infinity).

add_entries(Pid, Entries) ->
    gen_server:call(Pid, {add_entries, Entries}, infinity).

remove_entries(Pid, Entries) ->
    gen_server:call(Pid, {remove_entries, Entries}, infinity).
