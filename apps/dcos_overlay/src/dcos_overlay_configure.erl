%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 9:27 PM
%%%-------------------------------------------------------------------
-module(dcos_overlay_configure).
-author("sdhillon").
-author("dgoel").

%% API
-export([start_link/2, stop/1, maybe_configure/1, maybe_configure_and_reply/2]).

-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").

start_link(reply, LashupEvent) ->
   MyPid = self(),
   spawn_link(?MODULE, maybe_configure_and_reply, [LashupEvent, MyPid]);
start_link(noreply, LashupEvent) ->
   spawn_link(?MODULE, maybe_configure, [LashupEvent]).

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

reply(Pid, Msg) ->
    Pid ! Msg.

maybe_configure_and_reply(LashupEvent, MyPid) ->
    maybe_configure(LashupEvent),
    reply(MyPid, {dcos_overlay_configure, applied_config, LashupEvent}).

maybe_configure(LashupEvent) ->
    lager:debug("Started applying config ~p~n", [LashupEvent]),
    KnownOverlays = dcos_overlay_poller:overlays(),
    lists:map(
        fun(Overlay) -> try_configure_overlay(LashupEvent, Overlay) end,
        KnownOverlays
    ),
    lager:debug("Done applying config ~p for overlays ~p~n", [LashupEvent, KnownOverlays]).

try_configure_overlay(LashupEvent, Overlay) ->
    #mesos_state_agentoverlayinfo{info = #mesos_state_overlayinfo{subnet = Subnet}} = Overlay,
    ParsedSubnet = parse_subnet(Subnet),
    try_configure_overlay2(LashupEvent, Overlay, ParsedSubnet).

-type prefix_len() :: 0..32.
-spec(parse_subnet(Subnet :: binary()) -> {inet:ipv4_address(), prefix_len()}).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_ipv4_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 32,
    {IP, PrefixLen}.

try_configure_overlay2(_LashupEvent = #{key := [navstar, overlay, Subnet], value := LashupValue},
    Overlay, ParsedSubnet) when Subnet == ParsedSubnet ->
    lists:map(
        fun(Value) -> maybe_configure_overlay_entry(Overlay, Value) end,
        LashupValue
    );
try_configure_overlay2(_Event, _Overlay, _ParsedSubnet) ->
    ok.

maybe_configure_overlay_entry(Overlay, {{VTEPIPPrefix, riak_dt_map}, Value}) ->
    MyIP = dcos_overlay_poller:ip(),
    case lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, Value) of
        {_, MyIP} ->
            ok;
        _Any ->
            configure_overlay_entry(Overlay, VTEPIPPrefix, Value)
    end.

configure_overlay_entry(Overlay, _VTEPIPPrefix = {VTEPIP, _PrefixLen}, LashupValue) ->
    #mesos_state_agentoverlayinfo{
        backend = #mesos_state_backendinfo{
            vxlan = #mesos_state_vxlaninfo{
                vtep_name = VTEPName
            }
        }
    } = Overlay,
    {_, MAC} = lists:keyfind({mac, riak_dt_lwwreg}, 1, LashupValue),
    {_, AgentIP} = lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, LashupValue),
    {_, {SubnetIP, SubnetPrefixLen}} = lists:keyfind({subnet, riak_dt_lwwreg}, 1, LashupValue),
    FormattedMAC = vtep_mac(MAC),
    FormattedAgentIP = inet:ntoa(AgentIP),
    FormattedVTEPIP = inet:ntoa(VTEPIP),
    FormattedSubnetIP = inet:ntoa(SubnetIP),

    %% TEST only : writes the parameters to a file
    maybe_print_parameters([FormattedAgentIP, binary_to_list(VTEPName),
                            FormattedVTEPIP, FormattedMAC, 
                            FormattedSubnetIP, SubnetPrefixLen]),

    %ip neigh replace 5.5.5.5 lladdr ff:ff:ff:ff:ff:ff dev eth0 nud permanent
    {ok, _} = dcos_overlay_helper:run_command("ip neigh replace ~s lladdr ~s dev ~s nud permanent",
        [FormattedVTEPIP, FormattedMAC, VTEPName]),
    %bridge fdb add to 00:17:42:8a:b4:05 dst 192.19.0.2 dev vxlan0
    {ok, _} = dcos_overlay_helper:run_command("bridge fdb replace to ~s dst ~s dev ~s", [FormattedMAC, FormattedAgentIP, VTEPName]),

    {ok, _} = dcos_overlay_helper:run_command("ip route replace ~s/32 via ~s table 42", [FormattedAgentIP, FormattedVTEPIP]),
    {ok, _} = dcos_overlay_helper:run_command("ip route replace ~s/~B via ~s", [FormattedSubnetIP, SubnetPrefixLen, FormattedVTEPIP]).

vtep_mac(IntList) ->
    HexList = lists:map(fun(X) -> erlang:integer_to_list(X, 16) end, IntList),
    lists:flatten(string:join(HexList, ":")).

-ifdef(TEST).
maybe_print_parameters(Parameters) ->
    {ok, PrivDir} = application:get_env(dcos_overlay, outputdir),
    File = filename:join(PrivDir, node()),
    ok = file:write_file(File, io_lib:fwrite("~p.\n",[Parameters]), [append]).

-else.
maybe_print_parameters(_) ->
    ok.
-endif.
