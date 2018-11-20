-module(dcos_net_mesos_listener_tests).

-include_lib("eunit/include/eunit.hrl").

-export([
    basic_setup/0,
    hello_overlay_setup/0,
    pod_tasks_setup/0,
    cleanup/1
]).

%%%===================================================================
%%% Tests
%%%===================================================================

basic_test_() ->
    {setup, fun basic_setup/0, fun cleanup/1, {with, [
        fun is_leader/1,
        fun basic_from_state/1,
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

pod_tasks_test_() ->
    {setup, fun pod_tasks_setup/0, fun cleanup/1, {with, [
        fun pod_tasks/1
    ]}}.

vip_labels_test() ->
    [RawData] = read_lines("vip-labels.json"),
    Data = jiffy:decode(RawData, [return_maps]),
    TaskId = <<"app.c9e19be4-6a94-11e8-bfc9-70b3d5800002">>,
    FrameworkId = <<"3de98647-82e7-4a22-8fb5-32df27c1ef69-0001">>,
    ?assertEqual(#{
        {FrameworkId, TaskId} => #{
            name => <<"app">>,
            runtime => mesos,
            framework => <<"marathon">>,
            agent_ip => {172, 17, 0, 3},
            task_ip => [{172, 17, 0, 3}],
            ports => [
                #{name => <<"foo">>, protocol => tcp,
                  port => 9999, vip => [<<"/abc:80">>, <<"/cbd:80">>,
                                        <<"def:80">>]},
                #{name => <<"bar">>, protocol => tcp,
                  port => 10000, vip => [<<"jkl:80">>]},
                #{name => <<"baz">>, protocol => tcp,
                  port => 10001, vip => [<<"/xyz:443">>]},
                #{name => <<"qux">>, protocol => tcp,
                  port => 10002}
            ],
            state => running,
            healthy => true
        }
    }, dcos_net_mesos_listener:from_state(Data)).

dns_hostname_test() ->
    [RawData] = read_lines("dns-hostname.json"),
    Data = jiffy:decode(RawData, [return_maps]),
    TaskId = <<"test.f12cc459-cb38-11e8-a264-2e431fa5cff2">>,
    FrameworkId = <<"d0a07cf9-7424-426b-b138-2be9d07b8e62-0001">>,
    ?assertEqual(#{
        {FrameworkId, TaskId} => #{
            name => <<"test">>,
            runtime => docker,
            framework => <<"marathon">>,
            agent_ip => {127, 0, 0, 1},
            task_ip => [{127, 0, 0, 1}],
            state => running
        }
    }, dcos_net_mesos_listener:from_state(Data)).

tcp_udp_test() ->
    [RawData] = read_lines("tcp-and-udp.json"),
    Data = jiffy:decode(RawData, [return_maps]),
    TaskId = <<"app.80eefa01-d956-11e8-8b68-70b3d5800002">>,
    FrameworkId = <<"0e559f52-e43a-497a-90b8-11688d98f60c-0000">>,
    ?assertEqual(#{
        {FrameworkId, TaskId} => #{
            name => <<"app">>,
            runtime => docker,
            framework => <<"marathon">>,
            agent_ip => {172, 17, 0, 3},
            task_ip => [{172, 17, 0, 3}],
            ports => [
                #{name => <<"http">>, protocol => tcp,
                  port => 6416, vip => [<<"/app:80">>]},
                #{name => <<"foobar">>, protocol => tcp,
                  port => 6417},
                #{name => <<"http">>, protocol => udp,
                  port => 6416, vip => [<<"/app:80">>]},
                #{name => <<"foobar">>, protocol => udp,
                  port => 6417}
            ],
            state => running,
            healthy => true
        }
    }, dcos_net_mesos_listener:from_state(Data)).

unhealthy_test() ->
    [RawData] = read_lines("unhealthy.json"),
    Data = jiffy:decode(RawData, [return_maps]),
    TaskId = <<"app.7a5a8aa6-d8be-11e8-9bf3-70b3d5800001">>,
    FrameworkId = <<"ca0f7f0e-30a7-471b-8e2e-500e1e8a3799-0000">>,
    ?assertEqual(#{
        {FrameworkId, TaskId} => #{
            name => <<"app">>,
            runtime => mesos,
            framework => <<"marathon">>,
            agent_ip => {172, 17, 0, 4},
            task_ip => [{9, 0, 1, 6}],
            ports => [
                #{name => <<"http">>, protocol => tcp,
                  port => 80, vip => [<<"/foobar:80">>]}
            ],
            state => running,
            healthy => false
        }
    }, dcos_net_mesos_listener:from_state(Data)).

%%%===================================================================
%%% Basic Tests
%%%===================================================================

is_leader(_Tasts) ->
    IsLeader = dcos_net_mesos_listener:is_leader(),
    ?assertEqual(true, IsLeader).

basic_from_state(Tasks) ->
    from_state("operator-api.json", Tasks).

none_on_host(Tasks) ->
    TaskId = <<"none-on-host.1458594c-2630-11e8-af52-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"none-on-host">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 17, 0, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 13977}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

none_on_dcos(Tasks) ->
    TaskId = <<"none-on-dcos.115c093a-2630-11e8-af52-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"none-on-dcos">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{9, 0, 2, 5}],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

ucr_on_host(Tasks) ->
    TaskId = <<"ucr-on-host.1755bacf-2630-11e8-af52-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"ucr-on-host">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{172, 17, 0, 3}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 10323}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

ucr_on_bridge(Tasks) ->
    TaskId = <<"ucr-on-bridge.1458805d-2630-11e8-af52-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"ucr-on-bridge">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{172, 31, 254, 3}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 15263, port => 8080}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

ucr_on_dcos(Tasks) ->
    TaskId = <<"ucr-on-dcos.145ec1ee-2630-11e8-af52-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"ucr-on-dcos">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{9, 0, 1, 6}],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

docker_on_host(Tasks) ->
    TaskId = <<"docker-on-host.116271db-2630-11e8-af52-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"docker-on-host">>,
        runtime => docker,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 17, 0, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 31168}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

docker_on_bridge(Tasks) ->
    TaskId = <<"docker-on-bridge.0ef76549-2630-11e8-af52-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"docker-on-bridge">>,
        runtime => docker,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 18, 0, 2}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 20560, port => 8080}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

docker_on_dcos(Tasks) ->
    TaskId = <<"docker-on-dcos.0ebe53e8-2630-11e8-af52-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"docker-on-dcos">>,
        runtime => docker,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{9, 0, 2, 130}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 8080}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

docker_on_ipv6(Tasks) ->
    {ok, IPv6} = inet:parse_ipv6_address("fd01:b::2:8000:0:2"),
    TaskId = <<"docker-on-ipv6.602453f2-28e7-11e8-8cba-70b3d5800001">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"docker-on-ipv6">>,
        runtime => docker,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 19, 0, 2}, IPv6],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 8080}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

pod_on_host(Tasks) ->
    TaskId = <<"pod-on-host.instance-ea1231bf-2930-11e8-96bf-70b3d5800001.app">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"pod-on-host">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        task_ip => [{172, 17, 0, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 28064}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

pod_on_bridge(Tasks) ->
    TaskId = <<"pod-on-bridge.instance-e9d06dcd-2930-11e8-96bf-70b3d5800001.app">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"pod-on-bridge">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{172, 31, 254, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 2254, port => 8080}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

pod_on_dcos(Tasks) ->
    TaskId = <<"pod-on-dcos.instance-ea1231be-2930-11e8-96bf-70b3d5800001.app">>,
    FrameworkId = <<"30257977-0153-499d-a5b0-35afd842ef4d-0001">>,
    ?assertEqual(#{
        name => <<"pod-on-dcos">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{9, 0, 1, 3}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 8080}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

%%%===================================================================
%%% Overlay Tests
%%%===================================================================

hello_overlay_world(Tasks) ->
    TaskId = <<"hello-world.cea59641-2bea-11e8-93f9-6a3d376ad59c">>,
    FrameworkId = <<"c620b0f5-ce56-472b-814a-aa36b40206af-0001">>,
    ?assertEqual(#{
        name => <<"hello-world">>,
        runtime => unknown,
        framework => <<"marathon">>,
        agent_ip => {10, 0, 0, 49},
        task_ip => [{10, 0, 0, 49}],
        ports => [
            #{name => <<"api">>, protocol => tcp,
              port => 19630, vip => [<<"/api.hello-world:80">>]}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

hello_overlay_server(Tasks) ->
    TaskId = <<"hello-overlay-0-server__7a7fe08f-7870-4def-a3ac-da5f18377dab">>,
    FrameworkId = <<"c620b0f5-ce56-472b-814a-aa36b40206af-0002">>,
    ?assertEqual(#{
        name => <<"hello-overlay-0-server">>,
        runtime => mesos,
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
    }, maps:get({FrameworkId, TaskId}, Tasks)).

hello_overlay_vip(Tasks) ->
    TaskId = <<"hello-overlay-vip-0-server__3b071c4d-ef05-4344-9910-867431def3d7">>,
    FrameworkId = <<"c620b0f5-ce56-472b-814a-aa36b40206af-0002">>,
    ?assertEqual(#{
        name => <<"hello-overlay-vip-0-server">>,
        runtime => mesos,
        framework => <<"hello-world">>,
        agent_ip => {10, 0, 0, 49},
        task_ip => [{9, 0, 2, 3}],
        ports => [
            #{name => <<"overlay-vip">>, protocol => tcp,
              port => 4044, vip => [<<"overlay-vip:80">>]}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

hello_overlay_host_vip(Tasks) ->
    TaskId = <<"hello-host-vip-0-server__2e5e76da-1d8c-4435-b152-70002de6ca9b">>,
    FrameworkId = <<"c620b0f5-ce56-472b-814a-aa36b40206af-0002">>,
    ?assertEqual(#{
        name => <<"hello-host-vip-0-server">>,
        runtime => mesos,
        framework => <<"hello-world">>,
        agent_ip => {10, 0, 0, 49},
        task_ip => [{10, 0, 0, 49}],
        ports => [
            #{name => <<"host-vip">>, protocol => tcp,
              port => 4044, vip => [<<"host-vip:80">>]}
        ],
        state => running
    }, maps:get({FrameworkId, TaskId}, Tasks)).

%%%===================================================================
%%% Pod Tasks Tests
%%%===================================================================

pod_tasks(Tasks) ->
    TaskId = <<"app.instance-caff1565-d0db-11e8-aa23-70b3d5800002.foo">>,
    Framework = <<"8ae294b7-a766-42d6-960c-ad8acf0f0db6-0000">>,
    Task = #{
        name => <<"app">>,
        runtime => mesos,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        task_ip => [{9, 0, 0, 2}],
        state => running
    },
    ?assertEqual(#{
        {Framework, TaskId} => Task
    }, Tasks).

%%%===================================================================
%%% From State Tests
%%%===================================================================

from_state(FileName, ExpectedTasks) ->
    Lines = read_lines(FileName),
    State = from_state_merge(Lines),
    Tasks = dcos_net_mesos_listener:from_state(State),
    ?assertEqual(ExpectedTasks, Tasks).

-define(FPATH, [<<"get_state">>, <<"get_frameworks">>, <<"frameworks">>]).
-define(TPATH, [<<"get_state">>, <<"get_tasks">>, <<"tasks">>]).

from_state_merge(Lines) ->
    lists:foldl(fun (Line, Acc) ->
        Obj = jiffy:decode(Line, [return_maps]),
        from_state_merge(Obj, Acc)
    end, #{<<"type">> => <<"GET_STATE">>}, Lines).

from_state_merge(#{<<"type">> := <<"SUBSCRIBED">>,
                  <<"subscribed">> := #{<<"get_state">> := State}}, Acc) ->
    Acc#{<<"get_state">> => State};
from_state_merge(#{<<"type">> := <<"FRAMEWORK_UPDATED">>,
                  <<"framework_updated">> :=
                        #{<<"framework">> := FObj}}, Acc) ->
    Path = [<<"framework_info">>, <<"id">>, <<"value">>],
    from_state_merge(Path, ?FPATH, FObj, Acc);
from_state_merge(#{<<"type">> := <<"TASK_ADDED">>,
                  <<"task_added">> := #{<<"task">> := TObj}}, Acc) ->
    Tasks = mget(?TPATH, Acc, []),
    mput(?TPATH, [TObj | Tasks], Acc);
from_state_merge(#{<<"type">> := <<"TASK_UPDATED">>,
                  <<"task_updated">> := #{<<"status">> := TObj}}, Acc) ->
    Path = [<<"task_id">>, <<"value">>],
    from_state_merge(Path, ?TPATH, TObj, Acc).

from_state_merge(Path, ObjPath, Obj, Acc) ->
    Id = mget(Path, Obj),
    Objs = mget(ObjPath, Acc, []),
    case mpartition(Path, Id, Objs) of
        {[], Objs} ->
            mput(ObjPath, [Obj | Objs], Acc);
        {[O], Objs0} ->
            Objs1 = [mmerge(O, Obj) | Objs0],
            mput(ObjPath, Objs1, Acc)
    end.

mget([Key], Obj) ->
    maps:get(Key, Obj);
mget([Key | Tail], Obj) ->
    Obj0 = maps:get(Key, Obj),
    mget(Tail, Obj0).

mget(Key, Obj, Default) ->
    try
        mget(Key, Obj)
    catch error:{badkey, _BadKey} ->
        Default
    end.

mput([Key], Value, Obj) ->
    maps:put(Key, Value, Obj);
mput([Key | Tail], Value, Obj) ->
    Child = maps:get(Key, Obj),
    Child0 = mput(Tail, Value, Child),
    maps:put(Key, Child0, Obj).

mpartition(Path, Value, List) ->
    lists:partition(fun (X) ->
        mget(Path, X) =:= Value
    end, List).

mmerge(#{} = A, #{} = B) ->
    maps:fold(fun (Key, ValueB, Acc) ->
        case maps:find(Key, Acc) of
            {ok, ValueA} ->
                Acc#{Key => mmerge(ValueA, ValueB)};
            error ->
                Acc#{Key => ValueB}
        end
    end, A, B);
mmerge(_A, B) ->
    B.

%%%===================================================================
%%% Setup & cleanup
%%%===================================================================

read_lines(FileName) ->
    {ok, Cwd} = file:get_cwd(),
    DataFile = filename:join([Cwd, "apps/dcos_net/test/", FileName]),
    {ok, Data} = file:read_file(DataFile),
    Lines = binary:split(Data, <<"\n">>, [global]),
    [ Line || Line <- Lines, Line =/= <<>> ].

basic_setup() ->
    setup("operator-api.json").

hello_world_setup() ->
    setup("hello-world.json").

hello_overlay_setup() ->
    setup("hello-overlay.json").

pod_tasks_setup() ->
    setup("pod-tasks.json").

setup(FileName) ->
    Lines = read_lines(FileName),

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
