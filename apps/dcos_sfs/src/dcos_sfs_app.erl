-module(dcos_sfs_app).
-behaviour(application).

-export([start/2, stop/1]).

-export([data_dir/0, block_size/0]).

start(_StartType, _StartArgs) ->
    dcos_net_app:load_config_files(dcos_sfs),
    dcos_sfs_sup:start_link().

stop(_State) ->
    ok.

-spec(data_dir() -> file:filename()).
data_dir() ->
    {ok, DataDir} = application:get_env(dcos_sfs, data_dir),
    DataDir.

-spec(block_size() -> pos_integer()).
block_size() ->
    application:get_env(dcos_sfs, block_size, 1048576). % 1MB
