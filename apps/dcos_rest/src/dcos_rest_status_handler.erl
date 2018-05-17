-module(dcos_rest_status_handler).

-export([
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    process/2
]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, process}
    ], Req, State}.

process(Req, State) ->
    try
        #{application := App} =
            cowboy_req:match_qs([{application, nonempty}], Req),
        binary_to_existing_atom(App, latin1)
    of
        Application ->
            Applications = application:which_applications(),
            case lists:keymember(Application, 1, Applications) of
                true ->
                    {<<>>, Req, State};
                false ->
                    Req0 = cowboy_req:reply(404, Req),
                    {stop, Req0, State}
            end
    catch _Class:_Error ->
        Req = cowboy_req:reply(400, Req),
        {stop, Req, State}
    end.
