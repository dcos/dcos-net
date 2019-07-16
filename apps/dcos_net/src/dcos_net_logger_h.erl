-module(dcos_net_logger_h).

-export([add_handler/0]).

%% Logger callbacks
-export([log/2, adding_handler/1, removing_handler/1,
    changing_config/3, filter_config/1]).

%% Lager callbacks
-export([init/1, handle_call/2, handle_event/2, handle_info/2]).

add_handler() ->
    prometheus_counter:new([
        {name, erlang_vm_logger_events_total},
        {help, "Logger events count"},
        {labels, [level]}
    ]),
    gen_event:add_handler(lager_event, ?MODULE, notice),
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
%%% Lager callbacks
%%%===================================================================

init(Opts) ->
    {ok, Opts}.

handle_call(get_loglevel, State) ->
    {ok, State, State};
handle_call({set_loglevel, State}, _State) ->
    {ok, ok, State};
handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event({log, Message}, State) ->
    Severity = lager_msg:severity(Message),
    safe_inc(erlang_vm_logger_events_total, [Severity], 1),
    {ok, State};
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

safe_inc(Name, LabelValues, Value) ->
    try
        prometheus_counter:inc(Name, LabelValues, Value)
    catch error:_Error ->
        ok
    end.
