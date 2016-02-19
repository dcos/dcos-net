-module(dcos_dns_app).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(application).

-include("dcos_dns.hrl").

-define(COMPILE_OPTIONS,
        [verbose,
         report_errors,
         report_warnings,
         no_error_module_mismatch,
         {parse_transform, dcos_dns_module_transform},
         {source, undefined}]).

%% Application callbacks
-export([start/2, stop/1, wait_for_reqid/2]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    override_erldns_handlers(),
    dcos_dns_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
override_erldns_handlers() ->
    {_, Bin, _} = code:get_object_code(?ERLDNS_HANDLER),
    {ok, {_, [{abstract_code, {_, AbstractCode}}]}} = beam_lib:chunks(Bin, [abstract_code]),
    {ok, Module, NewBin} = compile:forms(AbstractCode, ?COMPILE_OPTIONS),
    ModStr = atom_to_list(Module),
    {module, Module} = code:load_binary(Module, ModStr, NewBin).

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
