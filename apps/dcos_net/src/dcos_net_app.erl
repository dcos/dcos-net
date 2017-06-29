%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module(dcos_net_app).

-behaviour(application).

-define(DEFAULT_CONFIG_DIR, "/opt/mesosphere/etc/dcos-net.config.d").
-define(MASTERS_KEY, {masters, riak_dt_orswot}).

%% Application callbacks
-export([
    start/2,
    stop/1,
    load_config_files/1
]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    load_config_files(),
    maybe_add_master(),
    dcos_net_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

maybe_add_master() ->
    case application:get_env(dcos_net, is_master, false) of
        false ->
            ok;
        true ->
            add_master()
    end.

add_master() ->
    Masters = lashup_kv:value([masters]),
    case orddict:find(?MASTERS_KEY, Masters) of
        error ->
            add_master2();
        {ok, Value} ->
            add_master2(Value)
    end.
add_master2(OldMasterList) ->
    case lists:member(node(), OldMasterList) of
        true ->
            ok;
        false ->
            add_master2()
    end.
add_master2() ->
    lashup_kv:request_op([masters],
        {update, [
            {update, ?MASTERS_KEY, {add, node()}}
        ]}).

load_config_files() ->
    load_config_files(undefined).

-spec load_config_files(App :: atom()) -> ok.
load_config_files(App) ->
    case file:list_dir(?DEFAULT_CONFIG_DIR) of
      {ok, []} ->
        lager:info("Found an empty config directory: ~p", [?DEFAULT_CONFIG_DIR]);
      {error, enoent} ->
        lager:info("Couldn't find config directory: ~p", [?DEFAULT_CONFIG_DIR]);
      {ok, Filenames} ->
        AbsFilenames = lists:map(fun abs_filename/1, Filenames),
        lists:foreach(fun (Filename) ->
            load_config_file(App, Filename)
        end, AbsFilenames)
    end.

abs_filename(Filename) ->
    filename:absname(Filename, ?DEFAULT_CONFIG_DIR).

load_config_file(App, Filename) ->
    case file:consult(Filename) of
        {ok, []} ->
            lager:info("Found an empty config file: ~p~n", [Filename]);
        {error, eacces} ->
            lager:info("Couldn't load config: ~p", [Filename]);
        {ok, Result} ->
            load_config(App, Result),
            lager:info("Loaded config: ~p", [Filename])
    end.

load_config(App, [Result]) ->
    lists:foreach(fun (AppOptions) ->
        load_app_config(App, AppOptions)
    end, Result).

load_app_config(undefined, {App, Options}) ->
    load_app_config(App, {App, Options});
load_app_config(App, {App, Options}) ->
    lists:foreach(fun ({OptionKey, OptionValue}) ->
        application:set_env(App, OptionKey, OptionValue)
    end, Options);
load_app_config(_App, _AppOptions) ->
    ok.
