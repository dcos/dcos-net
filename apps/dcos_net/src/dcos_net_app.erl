%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module(dcos_net_app).

-behaviour(application).

-define(MASTERS_KEY, {masters, riak_dt_orswot}).

%% Application callbacks
-export([
    start/2,
    stop/1,
    config_dir/0,
    load_config_files/1,
    dist_port/0,
    is_master/0
]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    load_environment_variables(),
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

load_environment_variables() ->
    lists:foreach(fun load_environment_variables/1, [
        {"STATSD_UDP_HOST", dcos_net, statsd_udp_host, string},
        {"STATSD_UDP_PORT", dcos_net, statsd_udp_port, integer}
    ]).

load_environment_variables({Key, App, AppKey, Type}) ->
    case os:getenv(Key) of
        false -> ok;
        Value ->
            Value0 = var_to_value(Value, Type),
            application:set_env(App, AppKey, Value0)
    end.

var_to_value(Value, string) ->
    Value;
var_to_value(Value, integer) ->
    list_to_integer(Value).

load_config_files() ->
    load_config_files(undefined).

-spec load_config_files(App :: atom()) -> ok.
load_config_files(App) ->
    ConfigDir = config_dir(),
    case file:list_dir(ConfigDir) of
      {ok, []} ->
        lager:info("Found an empty config directory: ~p", [ConfigDir]);
      {error, enoent} ->
        lager:info("Couldn't find config directory: ~p", [ConfigDir]);
      {ok, Filenames} ->
        lists:foreach(fun (Filename) ->
            AbsFilename = filename:absname(Filename, ConfigDir),
            load_config_file(App, AbsFilename)
        end, Filenames)
    end.

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
    ConfigDir = config_dir(),
    try
        case erl_prim_loader:list_dir(ConfigDir) of
            {ok, Filenames} ->
                dist_port(Filenames, ConfigDir);
            error ->
                {error, list_dir}
        end
    catch _:Err ->
        {error, Err}
    end.

-spec(dist_port([file:filename()], file:filename()) ->
    {ok, inet:port_number()} | {error, atom()}).
dist_port([], _Dir) ->
    {error, not_found};
dist_port([Filename|Filenames], Dir) ->
    AbsFilename = filename:absname(Filename, Dir),
    case consult(AbsFilename) of
        {ok, Data} ->
            case find(dcos_net, dist_port, Data) of
                {ok, Port} ->
                    {ok, Port};
                false ->
                    dist_port(Filenames, Dir)
            end;
        {error, _Error} ->
            dist_port(Filenames, Dir)
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

-spec(find(App, Key, Data) -> {ok, Value} | false
    when Data :: [{atom(), [{atom(), term()}]} | file:filename()],
         App :: atom(), Key :: atom(), Value :: term()).
find(App, Key, Data) ->
    case lists:keyfind(App, 1, Data) of
        {App, Config} ->
            case lists:keyfind(Key, 1, Config) of
                {Key, Value} ->
                    {ok, Value};
                false ->
                    false
            end;
        false ->
            false
    end.


%%====================================================================
%% config dir
%%====================================================================

-define(TOKEN_DOT, [{dot, erl_anno:new(1)}]).
-define(DEFAULT_CONFIG_DIR, "/opt/mesosphere/etc/dcos-net.config.d").

-type config_dir_r() :: {ok, file:filename()} | undefined.

-spec(config_dir() -> file:filename()).
config_dir() ->
    config_dir([
        fun config_dir_env/0,
        fun config_dir_arg/0,
        fun config_dir_sys/0
    ]).

-spec(config_dir([fun (() -> config_dir_r())]) -> file:filename()).
config_dir([]) ->
    ?DEFAULT_CONFIG_DIR;
config_dir([Fun|Funs]) ->
    case Fun() of
        {ok, ConfigDir} ->
            ConfigDir;
        undefined ->
            config_dir(Funs)
    end.

-spec(config_dir_env() -> config_dir_r()).
config_dir_env() ->
    application:get_env(dcos_net, config_dir).

-spec(config_dir_arg() -> config_dir_r()).
config_dir_arg() ->
    case init:get_argument(dcos_net) of
        {ok, Args} ->
            Args0 = lists:map(fun list_to_tuple/1, Args),
            case lists:keyfind("config_dir", 1, Args0) of
                {"config_dir", Value} ->
                    {ok, Tokens, _} = erl_scan:string(Value),
                    {ok, _} = erl_parse:parse_term(Tokens ++ ?TOKEN_DOT);
                false ->
                    undefined
            end;
        error -> undefined
    end.

-spec(config_dir_sys() -> config_dir_r()).
config_dir_sys() ->
    case init:get_argument(config) of
        error -> undefined;
        {ok, [SysConfig|_]} ->
            get_env(SysConfig, dcos_net, config_dir)
    end.

-spec(get_env(SysConfig, App, Key) -> {ok, Value} | undefined
    when SysConfig :: file:filename() | any(),
         App :: atom(), Key :: atom(), Value :: atom()).
get_env(SysConfig, App, Key) ->
    case consult(SysConfig) of
        {ok, Data} ->
            case find(App, Key, Data) of
                {ok, ConfigDir} ->
                    {ok, ConfigDir};
                false ->
                    Filename = lists:last(Data),
                    get_env(Filename, App, Key)
            end;
        {error, _Error} ->
            undefined
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
