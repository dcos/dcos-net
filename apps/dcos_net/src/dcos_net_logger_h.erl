-module(dcos_net_logger_h).

-export([add_handler/0]).

%% Logger callbacks
-export([log/2, adding_handler/1, removing_handler/1,
    changing_config/3, filter_config/1]).

add_handler() ->
    prometheus_counter:new([
        {name, erlang_vm_logger_events_total},
        {help, "Logger events count"},
        {labels, [level]}
    ]),
    logger:add_handler(?MODULE, ?MODULE, #{level => notice}).

%%%===================================================================
%%% Logger callbacks
%%%===================================================================

adding_handler(Config) ->
    {ok, Config}.

changing_config(_SetOrUpdate, _OldConfig, NewConfig) ->
    {ok, NewConfig}.

removing_handler(_Config) ->
    ok.

log(#{level := Level}, _Config) ->
    safe_inc(erlang_vm_logger_events_total, [Level], 1).

filter_config(Config) ->
    Config.

%%%===================================================================
%%% Internal functions
%%%===================================================================

safe_inc(Name, LabelValues, Value) ->
    try
        prometheus_counter:inc(Name, LabelValues, Value)
    catch error:_Error ->
        ok
    end.
