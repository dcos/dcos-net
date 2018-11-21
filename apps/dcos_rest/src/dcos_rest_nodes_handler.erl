-module(dcos_rest_nodes_handler).

-export([
    init/2,
    rest_init/2,
    allowed_methods/2,
    content_types_provided/2,
    get_metadata/2
]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

rest_init(Req, Opts) ->
    {ok, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, get_metadata}
    ], Req, State}.

get_metadata(Req, State) ->
    #{force := Opts} =
        cowboy_req:match_qs(
            [{force,
              fun (_, _) -> {ok, [force_refresh]} end,
              []}], Req),
    Data = dcos_net_node:get_metadata(Opts),
    Result =
        maps:fold(fun(K, V, Acc) ->
            [get_node(K, V) | Acc]
        end, [], Data),
    {jiffy:encode(Result), Req, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(get_node(inet:ip4_address(), dcos_net_node:metadata()) ->
    jiffy:json_object()).
get_node(PrivateIP, Metadata) ->
    #{public_ips := PublicIPs,
      hostname := Hostname,
      updated := Updated} = Metadata,

    #{private_ip => ntoa(PrivateIP),
      public_ips => [ntoa(IP) || IP <- PublicIPs],
      hostname => Hostname,
      updated => iso8601(Updated)}.

-spec(iso8601(non_neg_integer()) -> binary()).
iso8601(Timestamp) ->
    Opts = [{unit, millisecond}, {offset, "Z"}],
    DateTime = calendar:system_time_to_rfc3339(Timestamp, Opts),
    list_to_binary(DateTime).

-spec(ntoa(inet:ip_address()) -> binary()).
ntoa(IP) ->
    iolist_to_binary(inet:ntoa(IP)).
