-module(dcos_overlay_mockhttp_frontend).

-include_lib("common_test/include/ct.hrl").

% To mock cowboy
-export([init/2, content_types_provided/2,
         allowed_methods/2, to_protobuf/2]).

init(Req, Opts) ->
  {cowboy_rest, Req, Opts}.

content_types_provided(Req, Opts) ->
  {[{<<"application/x-protobuf">>, to_protobuf}], Req, Opts}.

allowed_methods(Req, Opts) ->
  {[<<"GET">>], Req, Opts}.

to_protobuf(Req, Opts = [overlay]) ->
  Node = cowboy_req:header(<<"node">>, Req),
  {ok, Data} = gen_server:call('dcos_overlay_mockhttp_backend', {data, Node}),
  {mesos_state_overlay_pb:encode_msg(Data), Req, Opts}.
