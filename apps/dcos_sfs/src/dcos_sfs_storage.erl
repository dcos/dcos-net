-module(dcos_sfs_storage).

-export([
    save/3,
    read/1
]).

-export_type([body_fun/0, send_fun/0, read_fun/0]).

-type body_fun(State, Data) ::
    fun((State) -> {ok, Data, State} | {more, Data, State} | {error, atom()}).
-type body_fun() :: body_fun(term(), binary()).
-type send_fun() :: (fun ((binary()) -> ok | {error, atom()})).
-type read_fun() :: (fun ((send_fun()) -> any())).
-type crypto_cxt() :: term().


%%%===================================================================
%%% Save
%%%===================================================================

-spec(save(Path :: [binary()], Fun :: body_fun(), State) ->
    {ok, Metadata, State} | {error, Error :: atom(), State}
        when State :: term(), Metadata :: #{}).
save(Path, Fun, State) ->
    DataDir = dcos_sfs_app:data_dir(),
    Filename = filename:join([DataDir | Path]),
    case filelib:ensure_dir(Filename) of
        ok ->
            case file:open(Filename, [raw, binary, write, exclusive]) of
                {ok, Fd} ->
                    Context = crypto:hash_init(sha512),
                    save_loop(Fd, #{}, Context, Fun, State);
                {error, eexist} ->
                    {error, eexist, State};
                {error, Error} ->
                    _ = file:delete(Filename),
                    {error, Error, State}
            end;
        {error, Error} ->
            {error, Error, State}
    end.

-spec(save_loop(file:fd(), Metadata, crypto_cxt(), body_fun(), State) ->
    {ok, Metadata, State} | {error, Error :: atom(), State}
        when State :: term(), Metadata :: #{}).
save_loop(Fd, Metadata, Context, Fun, State) ->
    case Fun(State) of
        {ok, Data, State0} ->
            Context0 = crypto:hash_update(Context, Data),
            case file:write(Fd, Data) of
                {error, Error} ->
                    _ = crypto:hash_final(Context),
                    {error, Error, State0};
                ok ->
                    case file:sync(Fd) of
                        {error, Error} ->
                            _ = crypto:hash_final(Context),
                            {error, Error, State0};
                        ok ->
                            Hash = crypto:hash_final(Context0),
                            Size = maps:get(size, Metadata, 0) + size(Data),
                            {ok, Metadata#{sha512 => Hash, size => Size}, State0}
                    end
            end;
        {more, Data, State0} ->
            Context0 = crypto:hash_update(Context, Data),
            case file:write(Fd, Data) of
                {error, Error} ->
                    _ = crypto:hash_final(Context),
                    {error, Error, State0};
                ok ->
                    Size = maps:get(size, Metadata, 0) + size(Data),
                    save_loop(Fd, Metadata#{size => Size}, Context0, Fun, State0)
            end;
        {error, Error} ->
            _ = crypto:hash_final(Context),
            {error, Error, State}
    end.

%%%===================================================================
%%% Read
%%%===================================================================

-spec(read(Path :: [binary()]) -> {ok, read_fun()} | {error, file:posix()}).
read(Path) ->
    DataDir = dcos_sfs_app:data_dir(),
    Filename = filename:join([DataDir | Path]),
    case file:open(Filename, [read]) of
        {ok, Fd} ->
            BlockSize = dcos_sfs_app:block_size(),
            {ok, fun (SendFun) ->
                read_fun(SendFun, Fd, BlockSize)
            end};
        {error, Error} ->
            {error, Error}
    end.

-spec(read_fun(send_fun(), file:fd(), pos_integer()) -> ok | {error, file:posix()}).
read_fun(SendFun, Fd, BlockSize) ->
    case file:read(Fd, BlockSize) of
        {ok, Data} ->
            ok = SendFun(Data),
            read_fun(SendFun, Fd, BlockSize);
        eof ->
            ok = SendFun(<<>>),
            file:close(Fd)
    end.
