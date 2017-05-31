%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module('dcos_dns_app').

-behaviour(application).

%% Application callbacks
-export([
    start/2,
    stop/1
]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    dcos_net_app:load_config_files(dcos_dns),
    'dcos_dns_sup':start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.
