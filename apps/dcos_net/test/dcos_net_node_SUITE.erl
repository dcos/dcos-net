-module(dcos_net_node_SUITE).

-export([
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2,
    get_metadata/1
]).

all() ->
    [get_metadata].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_, Config) ->
    {ok, _} = application:ensure_all_started(mnesia),
    {ok, _} = application:ensure_all_started(lashup),
    {ok, Pid} = dcos_net_node:start_link(),
    ok = wait_ready(Pid),
    Config.

end_per_testcase(_, _Config) ->
    Pid = whereis(dcos_net_node),
    unlink(Pid),
    exit(Pid, kill),

    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    ok.

wait_ready(Pid) ->
    timer:sleep(100),
    case erlang:process_info(Pid, current_stacktrace) of
        {current_stacktrace, [{gen_server, loop, _, _} | _ST]} ->
            ok;
        {current_stacktrace, []} ->
            ok;
        {current_stacktrace, _ST} ->
            wait_ready(Pid)
    end.

get_metadata(_Config) ->
    Dump = dcos_net_node:get_metadata(),
    #{{0, 0, 0, 0} := #{updated := A}} = Dump,
    ForceDump = dcos_net_node:get_metadata([force_refresh]),
    #{{0, 0, 0, 0} := #{updated := B}} = ForceDump,
    A < B.
