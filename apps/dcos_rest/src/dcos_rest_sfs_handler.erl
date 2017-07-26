-module(dcos_rest_sfs_handler).

-export([
    init/3,
    rest_init/2,
    service_available/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    read_file/2,
    process/2,
    delete_resource/2,
    stream/2,
    stream_fun/1
]).

init(_Transport, Req, Opts) ->
    {upgrade, protocol, cowboy_rest, Req, Opts}.

rest_init(Req, State) ->
    {ok, Req, State}.

service_available(Req, State=[stream]) ->
    {true, Req, State};
service_available(Req, State) ->
    {dcos_dns:is_master(), Req, State}.

allowed_methods(Req, State=[object]) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State=[stream]) ->
    {[
        {{<<"application">>, <<"x-json-stream">>, []}, stream}
    ], Req, State};
content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"octet-stream">>, []}, read_file}
    ], Req, State}.

content_types_accepted(Req, State) ->
    {[
        {'*', process}
    ], Req, State}.

delete_resource(Req, State) ->
    Time = erlang:system_time(nano_seconds),
    {Path, Req0} = cowboy_req:path_info(Req),
    Metadata = #{
        type => http,
        time => Time,
        flags => [delete]
    },
    case dcos_sfs_metadata:save(Path, Metadata) of
        ok ->
            {true, Req0, State};
        {error, Error} ->
            send_error_message(500, Error, Req0, State)
    end.

process(Req, State) ->
    Time = erlang:system_time(nano_seconds),
    {Path, Req0} = cowboy_req:path_info(Req),
    case dcos_sfs_storage:save(Path, fun cowboy_req:body/1, Req0) of
        {ok, FileMetadata, Req1} ->
            {URL, Req2} = get_url(Req1),
            {QSVals, Req3} = qs_vals(Req2),
            Metadata = #{
                type => http,
                time => Time,
                host => node(),
                url => URL
            },
            Metadata0 = maps:merge(Metadata, QSVals),
            Metadata1 = maps:merge(Metadata0, FileMetadata),
            case dcos_sfs_metadata:save(Path, Metadata1) of
                ok -> {true, Req3, State};
                {error, Error} ->
                    send_error_message(500, Error, Req3, State)
            end;
        {error, eexist, Req1} ->
            send_posix_error_message(409, eexist, Req1, State);
        {error, Error, Req1} ->
            send_posix_error_message(500, Error, Req1, State)
    end.

read_file(Req, State) ->
    {Path, Req0} = cowboy_req:path_info(Req),
    case dcos_sfs_storage:read(Path) of
        {ok, Fun} ->
            {{chunked, Fun}, Req, State};
        {error, enoent} ->
            {ok, Req1} = cowboy_req:reply(404, Req0),
            {halt, Req1, State}
    end.

stream(Req, State) ->
    {{chunked, fun ?MODULE:stream_fun/1}, Req, State}.

%%%===================================================================
%%% Streaming
%%%===================================================================

stream_fun(SendFun) ->
    dcos_sfs_metadata:stream(fun (Path, Metadata) ->
        stream_sendfun(SendFun, Path, Metadata)
    end).

stream_sendfun(SendFun, Path, #{flags := [delete]}) ->
    Metadata = #{
        path => Path,
        flags => [delete]
    },
    Data = jsx:encode(Metadata),
    SendFun([Data, $\n]);
stream_sendfun(SendFun, Path, Metadata) ->
    Metadata0 = Metadata#{
        path => Path,
        sha512 => hash_bin(maps:get(sha512, Metadata))
    },
    Data = jsx:encode(Metadata0),
    SendFun([Data, $\n]).

%%%===================================================================
%%% Errors
%%%===================================================================

send_posix_error_message(Code, Error, Req, State) ->
    ErrorMsg = io_lib:format("Error: ~s", [file:format_error(Error)]),
    send_error_message(Code, iolist_to_binary(ErrorMsg), Req, State).

send_error_message(Code, ErrorMsg, Req, State) when is_binary(ErrorMsg) ->
    {ok, Req0} = cowboy_req:reply(Code, [], ErrorMsg, Req),
    {halt, Req0, State};
send_error_message(Code, Error, Req, State) ->
    ErrorMsg = io_lib:format("Error: ~p", [Error]),
    send_error_message(Code, iolist_to_binary(ErrorMsg), Req, State).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(qs_vals(cowboy_req:req()) -> {URL :: binary(), cowboy_req:req()}).
qs_vals(Req) ->
    {QSVals, Req0} = cowboy_req:qs_vals(Req),
    Metadata =
        lists:foldl(
            fun ({<<"install">>, Value}, {Acc, ReqA}) ->
                    {Acc#{install => Value}, ReqA};
                ({_Key, _Value}, {Acc, ReqA}) ->
                    {Acc, ReqA}
            end, #{}, QSVals),
    {Metadata, Req0}.

-spec(get_url(cowboy_req:req()) -> {URL :: binary(), cowboy_req:req()}).
get_url(Req) ->
    Host = <<"leader.mesos">>,
    {Path, Req0} = cowboy_req:path(Req),
    Port = integer_to_binary(dcos_rest_app:port()),
    {<<"http://", Host/binary, ":", Port/binary, Path/binary>>, Req0}.

-spec(hash_bin(CryptoHash :: binary()) -> HexString :: binary()).
hash_bin(Hash) ->
    << <<(int_to_hex(H)):8>> || <<H:4>> <= Hash >>.

-spec(int_to_hex(char()) -> char()).
int_to_hex(N) when N =< 9 -> $0 + N;
int_to_hex(N) -> $a + N - 10.
