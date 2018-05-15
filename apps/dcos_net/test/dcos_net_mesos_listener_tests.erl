-module(dcos_net_mesos_listener_tests).

-include_lib("eunit/include/eunit.hrl").

-export([
    basic_setup/0,
    hello_overlay_setup/0,
    cleanup/1
]).

%%%===================================================================
%%% Tests
%%%===================================================================

basic_test_() ->
    {setup, fun basic_setup/0, fun cleanup/1, {with, [
        fun is_leader/1,
        fun none_on_host/1,
        fun none_on_dcos/1,
        fun ucr_on_host/1,
        fun ucr_on_bridge/1,
        fun ucr_on_dcos/1,
        fun docker_on_host/1,
        fun docker_on_bridge/1,
        fun docker_on_dcos/1,
        fun docker_on_ipv6/1,
        fun pod_on_host/1,
        fun pod_on_bridge/1,
        fun pod_on_dcos/1
    ]}}.

hello_world_test_() ->
    {setup, fun hello_world_setup/0, fun cleanup/1, {with, [
        fun (Tasks) -> ?assertEqual(#{}, Tasks) end
    ]}}.

hello_overlay_test_() ->
    {setup, fun hello_overlay_setup/0, fun cleanup/1, {with, [
        fun hello_overlay_world/1,
        fun hello_overlay_server/1,
        fun hello_overlay_vip/1,
        fun hello_overlay_host_vip/1
    ]}}.

%%%===================================================================
%%% Basic Tests
%%%===================================================================

is_leader(_Tasts) ->
    IsLeader = dcos_net_mesos_listener:is_leader(),
    ?assertEqual(true, IsLeader).

none_on_host(Tasks) ->
    TaskId = <<"none-on-host.1458594c-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"none-on-host">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 17, 0, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 13977}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

none_on_dcos(Tasks) ->
    TaskId = <<"none-on-dcos.115c093a-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"none-on-dcos">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{9, 0, 2, 5}],
        state => running
    }, maps:get(TaskId, Tasks)).

ucr_on_host(Tasks) ->
    TaskId = <<"ucr-on-host.1755bacf-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"ucr-on-host">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{172, 17, 0, 3}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 10323}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

ucr_on_bridge(Tasks) ->
    TaskId = <<"ucr-on-bridge.1458805d-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"ucr-on-bridge">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{172, 31, 254, 3}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 15263, port => 8080}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

ucr_on_dcos(Tasks) ->
    TaskId = <<"ucr-on-dcos.145ec1ee-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"ucr-on-dcos">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{9, 0, 1, 6}],
        state => running
    }, maps:get(TaskId, Tasks)).

docker_on_host(Tasks) ->
    TaskId = <<"docker-on-host.116271db-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"docker-on-host">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 17, 0, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 31168}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

docker_on_bridge(Tasks) ->
    TaskId = <<"docker-on-bridge.0ef76549-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"docker-on-bridge">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 18, 0, 2}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 20560, port => 8080}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

docker_on_dcos(Tasks) ->
    TaskId = <<"docker-on-dcos.0ebe53e8-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"docker-on-dcos">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{9, 0, 2, 130}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 8080}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

docker_on_ipv6(Tasks) ->
    {ok, IPv6} = inet:parse_ipv6_address("fd01:b::2:8000:0:2"),
    TaskId = <<"docker-on-ipv6.602453f2-28e7-11e8-8cba-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"docker-on-ipv6">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 19, 0, 2}, IPv6],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 8080}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

pod_on_host(Tasks) ->
    TaskId = <<"pod-on-host.instance-ea1231bf-2930-11e8-96bf-70b3d5800001.pod-on-host">>,
    ?assertEqual(#{
        name => <<"pod-on-host">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 17, 0, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 28064}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

pod_on_bridge(Tasks) ->
    TaskId = <<"pod-on-bridge.instance-e9d06dcd-2930-11e8-96bf-70b3d5800001.pod-on-bridge">>,
    ?assertEqual(#{
        name => <<"pod-on-bridge">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{172, 31, 254, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 2254, port => 8080}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

pod_on_dcos(Tasks) ->
    TaskId = <<"pod-on-dcos.instance-ea1231be-2930-11e8-96bf-70b3d5800001.pod-on-dcos">>,
    ?assertEqual(#{
        name => <<"pod-on-dcos">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{9, 0, 1, 3}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 8080}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

%%%===================================================================
%%% Overlay Tests
%%%===================================================================

hello_overlay_world(Tasks) ->
    TaskId = <<"hello-world.cea59641-2bea-11e8-93f9-6a3d376ad59c">>,
    ?assertEqual(#{
        name => <<"hello-world">>,
        framework => <<"marathon">>,
        agent_ip => {10, 0, 0, 49},
        task_ip => [{10, 0, 0, 49}],
        ports => [
            #{name => <<"api">>, protocol => tcp,
              port => 19630, vip => [<<"/api.hello-world:80">>]}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

hello_overlay_server(Tasks) ->
    TaskId = <<"hello-overlay-0-server__7a7fe08f-7870-4def-a3ac-da5f18377dab">>,
    ?assertEqual(#{
        name => <<"hello-overlay-0-server">>,
        framework => <<"hello-world">>,
        agent_ip => {10, 0, 0, 49},
        task_ip => [{9, 0, 2, 2}],
        ports => [
            #{name => <<"overlay-dummy">>,
              protocol => tcp, port => 1025},
            #{name => <<"overlay-dynport">>,
              protocol => tcp, port => 1026}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

hello_overlay_vip(Tasks) ->
    TaskId = <<"hello-overlay-vip-0-server__3b071c4d-ef05-4344-9910-867431def3d7">>,
    ?assertEqual(#{
        name => <<"hello-overlay-vip-0-server">>,
        framework => <<"hello-world">>,
        agent_ip => {10, 0, 0, 49},
        task_ip => [{9, 0, 2, 3}],
        ports => [
            #{name => <<"overlay-vip">>, protocol => tcp,
              port => 4044, vip => [<<"overlay-vip:80">>]}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

hello_overlay_host_vip(Tasks) ->
    TaskId = <<"hello-host-vip-0-server__2e5e76da-1d8c-4435-b152-70002de6ca9b">>,
    ?assertEqual(#{
        name => <<"hello-host-vip-0-server">>,
        framework => <<"hello-world">>,
        agent_ip => {10, 0, 0, 49},
        task_ip => [{10, 0, 0, 49}],
        ports => [
            #{name => <<"host-vip">>, protocol => tcp,
              port => 4044, vip => [<<"host-vip:80">>]}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

%%%===================================================================
%%% Setup & cleanup
%%%===================================================================

basic_setup() ->
    setup("operator-api.json").

hello_world_setup() ->
    setup("hello-world.json").

hello_overlay_setup() ->
    setup("hello-overlay.json").

setup(FileName) ->
    {ok, Cwd} = file:get_cwd(),
    DataFile = filename:join([Cwd, "apps/dcos_net/test/", FileName]),
    {ok, Data} = file:read_file(DataFile),
    Lines = binary:split(Data, <<"\n">>, [global]),

    application:load(dcos_net),
    application:set_env(dcos_net, is_master, true),

    meck:new(httpc),
    meck:expect(httpc, request,
        fun (post, Request, _HTTPOptions, _Options) ->
            {Pid, Ref} = {self(), make_ref()},
            URI = "http://nohost:5050/api/v1",
            {URI, _Headers, "application/json", _Body} = Request,
            proc_lib:spawn_link(fun () -> stream_start(Ref, Pid, Lines) end),
            {ok, Ref}
        end),
    meck:expect(httpc, stream_next,
        fun (Pid) ->
            Pid ! stream_next
        end),

    {ok, _Pid} = dcos_net_mesos_listener:start_link(),
    stream_wait(),

    {ok, _MonRef, Tasks} = dcos_net_mesos_listener:subscribe(),
    Tasks.

cleanup(_Tasks) ->
    Pid = whereis(dcos_net_mesos_listener),
    StreamPid = whereis(?MODULE),

    unlink(Pid),
    unlink(StreamPid),

    exit(Pid, kill),
    exit(StreamPid, kill),

    meck:unload(httpc).

stream_wait() ->
    lists:any(fun (_) ->
        try
            ?MODULE ! {stream_done, self()},
            receive stream_done -> ok end,
            true
        catch error:badarg ->
            timer:sleep(100),
            false
        end
    end, lists:seq(1, 20)).

%%%===================================================================
%%% Mesos Operator API Server
%%%===================================================================

stream_start(Ref, Pid, Lines) ->
    register(?MODULE, self()),
    Pid ! {http, {Ref, stream_start, [], self()}},
    stream_next(),
    stream_loop(Ref, Pid, Lines).

stream_loop(Ref, Pid, []) ->
    stream_done(),
    timer:sleep(500),
    Line = jiffy:encode(#{type => <<"HEARTBEAT">>}),
    stream_loop(Ref, Pid, [Line]);
stream_loop(Ref, Pid, [<<>>|Lines]) ->
    stream_loop(Ref, Pid, Lines);
stream_loop(Ref, Pid, [Line|Lines]) ->
    Size = integer_to_binary(size(Line)),
    Data = <<Size/binary, "\n", Line/binary>>,
    Pid ! {http, {Ref, stream, Data}},
    stream_next(),
    stream_loop(Ref, Pid, Lines).

stream_next() ->
    receive
        stream_next -> ok
    after
        10000 ->
            Info = recon:info(dcos_net_mesos_listener),
            error({timeout, Info})
    end.

stream_done() ->
    receive
        {stream_done, Pid} ->
            Pid ! stream_done
    after 0 ->
        ok
    end.
