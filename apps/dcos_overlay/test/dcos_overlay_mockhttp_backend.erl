-module(dcos_overlay_mockhttp_backend).
-behavior(gen_server).

-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").

-record(state, {agent = undefined}).

start_link(Args) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

init([]) ->
  {ok, #state{}}.

handle_call({data, Agent}, _From, State) ->
 Data = create_data(Agent),
 {reply, {ok, Data}, State}.

handle_cast(_Request, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

parse_node(Agent) ->
  [Bin1, _ ] = binary:split(Agent, <<"@">>),
  [_, Num] = binary:split(Bin1, [<<"master">>,<<"agent">>]),
  binary_to_list(Num).

create_data(Agent) ->
    NodeNumber = parse_node(Agent),
    HexNodeNumber = list_to_integer(NodeNumber, 16),
    Info = #mesos_state_overlayinfo{name = <<"dcos">>, prefix = 24, subnet = <<"9.0.0.0/8">>},
    MesosIP = list_to_binary(io_lib:format("9.0.~s.0/25", [NodeNumber])),
    MesosBridge = #mesos_state_bridgeinfo{name = <<"m-dcos">>, ip = MesosIP},
    DockerIP = list_to_binary(io_lib:format("9.0.~s.128/25", [NodeNumber])),
    DockerBridge = #mesos_state_bridgeinfo{name = <<"d-dcos">>, ip = DockerIP},
    Vtep_ip = list_to_binary(io_lib:format("44.128.0.~s/20", [NodeNumber])),
    Vtep_mac = list_to_binary(io_lib:format("70:b3:d5:80:00:~p", [HexNodeNumber])),
    Vxlan = #mesos_state_vxlaninfo{vni = 1024, vtep_ip = Vtep_ip, vtep_mac = Vtep_mac, vtep_name = <<"vtep1024">>},
    Backend = #mesos_state_backendinfo{vxlan = Vxlan},
    OverlayState = #'mesos_state_agentoverlayinfo.state'{status = 'STATUS_OK'},
    Subnet = list_to_binary(io_lib:format("9.0.~s.0/24", [NodeNumber])),
    Overlay = #mesos_state_agentoverlayinfo{info = Info, subnet = Subnet, backend = Backend, 
                  mesos_bridge = MesosBridge, docker_bridge = DockerBridge, state = OverlayState},
    AgentIP = list_to_binary(io_lib:format("10.0.0.~s",[NodeNumber])),
    #mesos_state_agentinfo{ip = AgentIP, overlays = [Overlay]}.
