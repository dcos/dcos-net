-module(dcos_rest_status_handler).

-export([
    init/3,
    allowed_methods/2,
    content_types_provided/2,
    process/2
]).

init(_Transport, Req, Opts) ->
    {upgrade, protocol, cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, process}
    ], Req, State}.

process(Req, State) ->
    {App, Req0} = cowboy_req:qs_val(<<"application">>, Req, <<>>),
    try binary_to_existing_atom(App, latin1) of
        Application ->
            Applications = application:which_applications(),
            case lists:keymember(Application, 1, Applications) of
                true ->
                    {<<>>, Req0, State};
                false ->
                    {ok, Req1} = cowboy_req:reply(404, Req0),
                    {halt, Req1, State}
            end
    catch error:badarg ->
        {ok, Req1} = cowboy_req:reply(400, Req0),
        {halt, Req1, State}
    end.
