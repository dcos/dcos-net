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
    load_config_files/1,
    dist_port/0,
    is_master/0
]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    load_config_files(),
    load_plugins(),
    dcos_net_sup:start_link().

stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

-spec(is_master() -> boolean()).
is_master() ->
    application:get_env(dcos_net, is_master, false).

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

%%====================================================================
%% dist_port
%%====================================================================

-spec(dist_port() -> {ok, inet:port_number()} | {error, atom()}).
dist_port() ->
    try
        case erl_prim_loader:list_dir(?DEFAULT_CONFIG_DIR) of
            {ok, Filenames} ->
                AbsFilenames = lists:map(fun abs_filename/1, Filenames),
                dist_port(AbsFilenames);
            error ->
                {error, list_dir}
        end
    catch _:Err ->
        {error, Err}
    end.

-spec(dist_port([file:filename()]) ->
    {ok, inet:port_number()} | {error, atom()}).
dist_port([]) ->
    {error, not_found};
dist_port([Filename|Filenames]) ->
    case consult(Filename) of
        {ok, Data} ->
            case get_dist_port(Data) of
                {ok, Port} ->
                    {ok, Port};
                {error, _Error} ->
                    dist_port(Filenames)
            end;
        {error, _Error} ->
            dist_port(Filenames)
    end.

-spec(get_dist_port([{atom(), [{atom(), term()}]}]) ->
    {ok, inet:port_number()} | {error, atom()}).
get_dist_port(Data) ->
    case lists:keyfind(dcos_net, 1, Data) of
        {dcos_net, Config} ->
            case lists:keyfind(dist_port, 1, Config) of
                {dist_port, Port} ->
                    {ok, Port};
                false ->
                    {error, not_found}
            end;
        false ->
            {error, not_found}
    end.

-spec(consult(file:filename()) -> {ok, term()} | {error, term()}).
consult(Filename) ->
    case prim_file:read_file(Filename) of
        {ok, Data} ->
            String = binary_to_list(Data),
            case erl_scan:string(String) of
                {ok, Tokens, _Line} ->
                    erl_parse:parse_term(Tokens);
                {error, Error, _Line} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

%%====================================================================
%% Plugins
%%====================================================================

load_plugins() ->
    Plugins = application:get_env(dcos_net, plugins, []),
    lists:foreach(fun load_plugin/1, Plugins).

load_plugin({App, AppPath}) ->
    case code:add_pathz(AppPath) of
        true ->
            load_modules(App, AppPath),
            case application:ensure_all_started(App, permanent) of
                {error, Error} ->
                    lager:error("Plugin ~p: ~p", [App, Error]);
                {ok, _Apps} -> ok
            end;
        {error, bad_directory} ->
            lager:error("Plugin ~p: bad_directory", [App])
    end.

load_modules(App, AppPath) ->
    AppFile = filename:join(AppPath, [App, ".app"]),
    {ok, [{application, App, AppData}]} = file:consult(AppFile),
    {modules, Modules} = lists:keyfind(modules, 1, AppData),
    lists:foreach(fun code:load_file/1, Modules).
