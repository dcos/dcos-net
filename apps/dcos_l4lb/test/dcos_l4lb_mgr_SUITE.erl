-module(dcos_l4lb_mgr_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    init_per_suite/1, end_per_suite/1,
    test_normalize/1
]).

all() -> [test_normalize].

init_per_suite(Config) ->
    application:load(dcos_l4lb),
    set_agent_dets_basedir(Config),
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    Config.

set_agent_dets_basedir(Config) ->
    PrivateDir = ?config(priv_dir, Config),
    application:set_env(dcos_l4lb, agent_dets_basedir, PrivateDir).

end_per_suite(Config) ->
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    Config.

test_normalize(_Config) ->
    Normalized =
        dcos_l4lb_mgr:normalize_services_and_dests({service(), [
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
