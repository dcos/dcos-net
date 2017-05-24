-module(dcos_overlay_mockhttp_frontend).

-include_lib("common_test/include/ct.hrl").
-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").

% To mock cowboy
-export([
    init/2,
    content_types_provided/2,
    allowed_methods/2,
    to_protobuf/2,
    create_data/1
]).

init(Req, Opts) ->
  {cowboy_rest, Req, Opts}.

content_types_provided(Req, Opts) ->
  {[{<<"application/x-protobuf">>, to_protobuf}], Req, Opts}.

allowed_methods(Req, Opts) ->
  {[<<"GET">>], Req, Opts}.

to_protobuf(Req, Opts = [overlay]) ->
  Node = cowboy_req:header(<<"node">>, Req),
  Data = create_data(Node),
  {mesos_state_overlay_pb:encode_msg(Data), Req, Opts}.

parse_node(Agent) ->
  [Bin1, _ ] = binary:split(Agent, <<"@">>),
  [_, Num] = binary:split(Bin1, [<<"master">>, <<"agent">>]),
  Num.

create_data(Agent) ->
    Node = parse_node(Agent),
    HexNode = integer_to_binary(binary_to_integer(Node, 16)),
    #mesos_state_agentinfo{
        ip = <<"10.0.0.", Node/binary>>,
        overlays = [
            #mesos_state_agentoverlayinfo{
                info = #mesos_state_overlayinfo{
                    name = <<"dcos">>,
                    prefix = 24,
                    subnet = <<"9.0.0.0/8">>
                },
                subnet = <<"9.0.", Node/binary, ".0/24">>,
                backend = #mesos_state_backendinfo{
                    vxlan = #mesos_state_vxlaninfo{
                        vni = 1024,
                        vtep_ip = <<"44.128.0.", Node/binary, "/20">>,
                        vtep_mac = <<"70:b3:d5:80:00:", HexNode/binary>>,
                        vtep_name = <<"vtep1024">>
                    }
                },
                mesos_bridge = #mesos_state_bridgeinfo{
                    name = <<"m-dcos">>,
                    ip = <<"9.0.", Node/binary, ".0/25">>
                },
                docker_bridge = #mesos_state_bridgeinfo{
                    name = <<"d-dcos">>,
                    ip = <<"9.0.", Node/binary, ".128/25">>
                },
                state = #'mesos_state_agentoverlayinfo.state'{
                    status = 'STATUS_OK'
                }
            }
        ]
    }.
