-module(dcos_dns_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

-include_lib("kernel/include/logger.hrl").

-define(CHILD(Module), #{id => Module, start => {Module, start_link, []}}).
-define(CHILD(Module, Custom), maps:merge(?CHILD(Module), Custom)).

start_link(Enabled) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Enabled]).

init([false]) ->
    {ok, {#{}, []}};
init([true]) ->
    %% Configure metrics.
    dcos_dns_handler:init_metrics(),
    dcos_dns:init_metrics(),

    %% Setup ready.spartan zone / record
    ok = dcos_dns_zone_setup(),
    ok = localhost_zone_setup(),
    ok = custom_zones_setup(),

    %% Systemd Sup intentionally goes last
    Children = [
        ?CHILD(dcos_dns_zk_record_server),
        ?CHILD(dcos_dns_config_loader_server),
        ?CHILD(dcos_dns_key_mgr, #{restart => transient}),
        ?CHILD(dcos_dns_listener)
    ],
    Children1 = maybe_add_udp_servers(Children),

    IsMaster = dcos_net_app:is_master(),
    MChildren =
        [?CHILD(dcos_dns_mesos_dns) || IsMaster] ++
        [?CHILD(dcos_dns_mesos) || IsMaster],

    sidejob:new_resource(
        dcos_dns_handler_sj, sidejob_supervisor,
        dcos_dns_config:handler_limit()),

    %% The top level sup should never die.
    {ok, {#{intensity => 10000, period => 1},
        MChildren ++ Children1
    }}.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
maybe_add_udp_servers(Children) ->
    case dcos_dns_config:udp_enabled() of
        true ->
            udp_servers() ++ Children;
        false ->
            Children
    end.

udp_servers() ->
    Addresses = dcos_dns_config:bind_ips(),
    lists:map(fun udp_server/1, Addresses).

udp_server(Address) ->
    #{
        id => {dcos_dns_udp_server, Address},
        start => {dcos_dns_udp_server, start_link, [Address]}
    }.

localhost_zone_setup() ->
    dcos_dns:push_zone(
        <<"localhost">>,
        [dcos_dns:dns_record(<<"localhost">>, {127, 0, 0, 1})]).

dcos_dns_zone_setup() ->
    dcos_dns:push_zone(
        <<"spartan">>, [
            dcos_dns:dns_record(<<"ready.spartan">>, {127, 0, 0, 1}),
            dcos_dns:dns_record(<<"ns.spartan">>, {198, 51, 100, 1})
        ]).

custom_zones_setup() ->
    Zones = application:get_env(dcos_dns, zones, #{}),
    maps:fold(fun (ZoneName, Zone, ok) ->
        ZoneName0 = to_binary(ZoneName),
        true = validate_zone_name(ZoneName0),
        Records = lists:map(fun (R) -> record(ZoneName0, R) end, Zone),
        dcos_dns:push_zone(ZoneName0, Records)
    end, ok, Zones).

-spec validate_zone_name(ZoneName :: binary()) -> boolean().
validate_zone_name(ZoneName) ->
    case dcos_dns_app:parse_upstream_name(ZoneName) of
        [<<"directory">>, <<"thisdcos">>, <<"l4lb">>  | _Labels] -> false;
        [<<"directory">>, <<"thisdcos">>, <<"mesos">> | _Labels] -> false;
        [<<"directory">>, <<"thisdcos">>, <<"dcos">>  | _Labels] -> false;
        [<<"directory">>, <<"thisdcos">>, _Zone | _Labels] -> true;
        _Labels -> false
    end.

-spec record(ZoneName :: binary(), Record :: maps:map()) -> dns:rr().
record(ZoneName, #{type := cname, name := CName, value := DName}) ->
    CName0 = list_to_binary(mesos_state:label(CName)),
    CName1 = <<CName0/binary, ".", ZoneName/binary>>,
    dcos_dns:cname_record(CName1, to_binary(DName));
record(_ZoneName, Record) ->
    ?LOG_ERROR("Unexpected format: ~p", [Record]),
    init:stop(1),
    error(stop).

-spec to_binary(term()) -> binary().
to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(List) when is_list(List) ->
    list_to_binary(List).
