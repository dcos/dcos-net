%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. May 2016 1:37 AM
%%%-------------------------------------------------------------------
-module(navstar_SUITE).
-author("sdhillon").
-include_lib("common_test/include/ct.hrl").
-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").

%% API
-export([all/0, deserialize_overlay/1]).

all() ->
    [deserialize_overlay].

deserialize_overlay(Config) ->
    DataDir = ?config(data_dir, Config),
    OverlayFilename = filename:join(DataDir, "overlay.bindata.pb"),
    {ok, OverlayData} = file:read_file(OverlayFilename),
    Msg = mesos_state_overlay_pb:decode_msg(OverlayData, mesos_state_agentinfo),
    <<"10.0.0.160:5051">> = Msg#mesos_state_agentinfo.ip.


