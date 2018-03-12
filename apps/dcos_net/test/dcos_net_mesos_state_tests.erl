-module(dcos_net_mesos_state_tests).

-include_lib("eunit/include/eunit.hrl").
all_test_() ->
    {setup, fun setup/0, fun cleanup/1, {with, [
        fun none_on_host/1,
        fun none_on_dcos/1,
        fun ucr_on_host/1,
        fun ucr_on_bridge/1,
        fun ucr_on_dcos/1,
        fun docker_on_host/1,
        fun docker_on_bridge/1,
        fun docker_on_dcos/1
    ]}}.

none_on_host(Tasks) ->
    TaskId = <<"none-on-host.1458594c-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"none-on-host">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        container_ip => [{172, 17, 0, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 13977}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

none_on_dcos(Tasks) ->
    TaskId = <<"none-on-dcos.115c093a-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"none-on-dcos">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        container_ip => [{9, 0, 2, 5}],
        ports => [
            #{name => <<"default">>, protocol => tcp,
              port => 0}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

ucr_on_host(Tasks) ->
    TaskId = <<"ucr-on-host.1755bacf-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"ucr-on-host">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        container_ip => [{172, 17, 0, 3}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 10323}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

ucr_on_bridge(Tasks) ->
    TaskId = <<"ucr-on-bridge.1458805d-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"ucr-on-bridge">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 3},
        container_ip => [{172, 31, 254, 3}],
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
        container_ip => [{9, 0, 1, 6}],
        ports => [
            #{name => <<"default">>, protocol => tcp,
              port => 0}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

docker_on_host(Tasks) ->
    TaskId = <<"docker-on-host.116271db-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"docker-on-host">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        container_ip => [{172, 17, 0, 4}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              host_port => 31168}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

docker_on_bridge(Tasks) ->
    TaskId = <<"docker-on-bridge.0ef76549-2630-11e8-af52-70b3d5800001">>,
    ?assertEqual(#{
        name => <<"docker-on-bridge">>,
        framework => <<"marathon">>,
        agent_ip => {172, 17, 0, 4},
        container_ip => [{172, 18, 0, 2}],
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
        container_ip => [{9, 0, 2, 130}],
        ports => [
            #{name => <<"http">>, protocol => tcp,
              port => 8080}
        ],
        state => running
    }, maps:get(TaskId, Tasks)).

%%%===================================================================
%%% Setup & cleanup
%%%===================================================================

setup() ->
    {ok, Cwd} = file:get_cwd(),
    DataFile = filename:join(Cwd, "apps/dcos_net/test/operator-api.json"),
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

    {ok, _Pid} = dcos_net_mesos_state:start_link(),
    stream_wait(),

    {ok, _MonRef, Tasks} = dcos_net_mesos_state:subscribe(),
    io:format(user, "~p~n", [Tasks]), % XXX
    Tasks.

cleanup(Config) ->
    Pid = whereis(dcos_net_mesos_state),
    StreamPid = whereis(?MODULE),

    unlink(Pid),
    unlink(StreamPid),

    exit(Pid, kill),
    exit(StreamPid, kill),

    meck:unload(httpc),

    Config.

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
            Info = recon:info(dcos_net_mesos_state),
            error({timeout, Info})
    end.

stream_done() ->
    receive
        {stream_done, Pid} ->
            Pid ! stream_done
    after 0 ->
        ok
    end.
