%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 03. Jun 2016 1:51 AM
%%%-------------------------------------------------------------------
-module(dcos_dns_world).
-author("sdhillon").


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVICES_URI, "https://kyd5j6245k.execute-api.us-west-2.amazonaws.com/prod/push").

%% API
-export([push_zone_to_world/2]).
-include("dcos_dns.hrl").
-include("dcos_dns_dcos_dns_pb.hrl").
-include_lib("dns/include/dns.hrl").



push_zone_to_world(ZoneName, NewRecords) ->
    case dcos_dns:key() of
        #{public_key := PublicKey, secret_key := SecretKey} ->
            push_zone_to_world(SecretKey, PublicKey, ZoneName, NewRecords);
        _ ->
            ok
    end.

%% TODO: REFACTOR
push_zone_to_world(SecretKey, PublicKey, ZoneName0, Records0) ->
    {ZoneName1, Records1} = dcos_dns_listener:convert_zone(PublicKey, ZoneName0, Records0),
    ZoneRecords = zone2proto(ZoneName1, Records1),
    ZoneBin = dcos_dns_dcos_dns_pb:encode_msg(ZoneRecords),
    ZoneBinSignature = binary_to_list(enacl:sign_detached(ZoneBin, SecretKey)),
    Options = [
        {timeout, application:get_env(?APP, timeout, ?DEFAULT_TIMEOUT)},
        {connect_timeout, application:get_env(?APP, connect_timeout, ?DEFAULT_CONNECT_TIMEOUT)}
    ],
    %% We don't retry this. Retry logic is too damn hard
    URI = application:get_env(?APP, services_uri, ?SERVICES_URI),
    %% I fucking hate AWS Lambda
    LambdaRequest = #{
        <<"publickey">> => base64:encode(PublicKey),
        <<"signature">> => base64:encode(ZoneBinSignature),
        <<"zone">> => base64:encode(ZoneBin),
        <<"zonename">> => ZoneName1
    },
    LambdaRequestBin = jsx:encode(LambdaRequest),
    Response = httpc:request(post, {URI, _Headers = [], "application/json", LambdaRequestBin}, Options, []),
    handle_response(Response),
    ok.
handle_response({ok, {_StatusLine, _Headers, Body}}) ->
    lager:debug("Success: ~p", [jsx:decode(list_to_binary(Body), [return_maps])]);
handle_response({error, Response}) ->
    lager:warning("Could not post to service: ~p", [Response]).

zone2proto(ZoneName, NewRecords) ->
    ProtoRecords = lists:filtermap(fun record2proto2/1, NewRecords),
    #dcos_dns_zone{name = ZoneName, records = ProtoRecords}.

record2proto2(X) ->
    case record2proto(X) of
        false ->
            false;
        Record = #dcos_dns_record{} ->
            {true, Record}
    end.

record2proto(#dns_rr{type = ?DNS_TYPE_A, name = Name, data = #dns_rrdata_a{ip = IP}}) ->
    #dcos_dns_record{
        name = Name,
        type = 'A',
        a_record = #dcos_dns_arecord{
            ip = ip_to_integer(IP)
        }
    };
record2proto(#dns_rr{type = ?DNS_TYPE_SRV, name = Name,
    data = #dns_rrdata_srv{target = Target, weight = Weight, priority = Priority, port = Port}}) ->
    #dcos_dns_record{
        name = Name,
        type = 'SRV',
        srv_record = #dcos_dns_srvrecord{
            priority = Priority,
            port = Port,
            weight = Weight,
            target = Target
        }
    };
record2proto(_) -> false.


-spec(ip_to_integer(inet:ip4_address()) -> 0..4294967295).
ip_to_integer(_IP = {A, B, C, D}) ->
    <<IntIP:32/integer>> = <<A, B, C, D>>,
    IntIP.

-ifdef(TEST).
example_zone() ->
    [{dns_rr,<<"_framework._tcp.marathon.mesos.thisdcos.directory">>,1,
        33,5,
        {dns_rrdata_srv,0,0,36241,
            <<"marathon.mesos.thisdcos.directory">>}},
        {dns_rr,<<"_leader._tcp.mesos.thisdcos.directory">>,1,33,5,
            {dns_rrdata_srv,0,0,5050,
                <<"leader.mesos.thisdcos.directory">>}},
        {dns_rr,<<"_leader._udp.mesos.thisdcos.directory">>,1,33,5,
            {dns_rrdata_srv,0,0,5050,
                <<"leader.mesos.thisdcos.directory">>}},
        {dns_rr,<<"_slave._tcp.mesos.thisdcos.directory">>,1,33,5,
            {dns_rrdata_srv,0,0,5051,
                <<"slave.mesos.thisdcos.directory">>}},
        {dns_rr,<<"leader.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{10,0,6,47}}},
        {dns_rr,<<"marathon.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{10,0,6,47}}},
        {dns_rr,<<"master.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{10,0,6,47}}},
        {dns_rr,<<"master0.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{10,0,6,47}}},
        {dns_rr,<<"mesos.thisdcos.directory">>,1,2,3600,
            {dns_rrdata_ns,<<"ns.spartan">>}},
        {dns_rr,<<"mesos.thisdcos.directory">>,1,6,3600,
            {dns_rrdata_soa,<<"ns.spartan">>,
                <<"support.mesosphere.com">>,1,60,180,86400,
                1}},
        {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{10,0,6,47}}},
        {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{172,17,0,1}}},
        {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{198,51,100,1}}},
        {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{198,51,100,2}}},
        {dns_rr,<<"root.ns1.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{198,51,100,3}}},
        {dns_rr,<<"slave.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{10,0,3,101}}},
        {dns_rr,<<"slave.mesos.thisdcos.directory">>,1,1,5,
            {dns_rrdata_a,{10,0,5,155}}}].

zone2proto_test() ->
    ExpectedZone = {dcos_dns_zone,<<"mesos.thisdcos.directory">>,
        [{dcos_dns_record,
            <<"_framework._tcp.marathon.mesos.thisdcos.directory">>,'SRV',
            {dcos_dns_srvrecord,0,0,
                <<"marathon.mesos.thisdcos.directory">>,36241},
            undefined},
            {dcos_dns_record,<<"_leader._tcp.mesos.thisdcos.directory">>,
                'SRV',
                {dcos_dns_srvrecord,0,0,
                    <<"leader.mesos.thisdcos.directory">>,5050},
                undefined},
            {dcos_dns_record,<<"_leader._udp.mesos.thisdcos.directory">>,
                'SRV',
                {dcos_dns_srvrecord,0,0,
                    <<"leader.mesos.thisdcos.directory">>,5050},
                undefined},
            {dcos_dns_record,<<"_slave._tcp.mesos.thisdcos.directory">>,
                'SRV',
                {dcos_dns_srvrecord,0,0,
                    <<"slave.mesos.thisdcos.directory">>,5051},
                undefined},
            {dcos_dns_record,<<"leader.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,167773743}},
            {dcos_dns_record,<<"marathon.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,167773743}},
            {dcos_dns_record,<<"master.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,167773743}},
            {dcos_dns_record,<<"master0.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,167773743}},
            {dcos_dns_record,<<"root.ns1.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,167773743}},
            {dcos_dns_record,<<"root.ns1.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,2886795265}},
            {dcos_dns_record,<<"root.ns1.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,3325256705}},
            {dcos_dns_record,<<"root.ns1.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,3325256706}},
            {dcos_dns_record,<<"root.ns1.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,3325256707}},
            {dcos_dns_record,<<"slave.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,167773029}},
            {dcos_dns_record,<<"slave.mesos.thisdcos.directory">>,'A',
                undefined,
                {dcos_dns_arecord,167773595}}]},
    Zone = example_zone(),
    ProtoRecord = zone2proto(<<"mesos.thisdcos.directory">>, Zone),

    ?assertEqual(ExpectedZone, ProtoRecord),
    dcos_dns_dcos_dns_pb:encode_msg(ProtoRecord, [{verify, true}]).

-endif.