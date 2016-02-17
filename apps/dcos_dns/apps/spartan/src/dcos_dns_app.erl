-module(dcos_dns_app).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, wait_for_reqid/2]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    dcos_dns_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @doc Wait for a response.
wait_for_reqid(ReqID, Timeout) ->
    receive
        {ReqID, ok} ->
            ok;
        {ReqID, ok, Val} ->
            {ok, Val}
    after Timeout ->
        {error, timeout}
    end.
