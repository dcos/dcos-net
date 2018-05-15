%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Jun 2016 3:37 AM
%%%-------------------------------------------------------------------
-module(dcos_dns_listener).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0, convert_zone/3]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {
    ref = erlang:error() :: reference()
}).
-define(RPC_TIMEOUT, 5000).
-define(MON_CALLBACK_TIME, 5000).
-define(RPC_RETRY_TIME, 15000).

-include("dcos_dns.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("dns/include/dns.hrl").

-define(SLIDE_WINDOW, 5). % seconds
-define(SLIDE_SIZE, 16).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the server
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! init,
    {ok, []}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, []) ->
    MatchSpec = ets:fun2ms(fun({?LASHUP_KEY('_')}) -> true end),
    {ok, Ref} = lashup_kv_events_helper:start_link(MatchSpec),
    {noreply, #state{ref = Ref}};
handle_info({lashup_kv_events, Event = #{ref := Reference}},
            State0 = #state{ref = Ref}) when Ref == Reference ->
    State1 = handle_event(Event, State0),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

zone(ZoneName, LashupValue) ->
    {_, Records} = lists:keyfind(?RECORDS_FIELD, 1, LashupValue),
    Sha = crypto:hash(sha, term_to_binary(Records)),
    {ZoneName, Sha, Records}.

handle_event(#{key := ?LASHUP_KEY(ZoneName), value := Value}, State) ->
    Zone = zone(ZoneName, Value),
    ok = push_zone(Zone),
    State.

push_zone(Zone = {ZoneName, Sha, Records}) ->
    Size = length(Records),
    Begin = erlang:monotonic_time(millisecond),
    ok = erldns_zone_cache:put_zone(Zone),
    lager:notice("~s was updated (~p records, sha: ~s)",
                 [ZoneName, Size, bin_to_hex(Sha)]),
    case sign_zone(Zone) of
        {no_key, _Zone} -> ok;
        {ok, SignedZone} ->
            ok = erldns_zone_cache:put_zone(SignedZone)
    end,
    m_notify(ZoneName, Begin, Size).

sign_zone(Zone = {ZoneName, _ZoneSha, Records}) ->
    case dcos_dns_key_mgr:keys() of
        false ->
            {no_key, Zone};
        #{public_key := PublicKey} ->
            {ZoneName0, Records0} = convert_zone(PublicKey, ZoneName, Records),
            Sha = crypto:hash(sha, term_to_binary(Records0)),
            {ok, {ZoneName0, Sha, Records0}}
    end.

convert_zone(PublicKey, ZoneName0, Records0) ->
    PublicKeyEncoded = zbase32:encode(PublicKey),
    NewPostfix = <<".", PublicKeyEncoded/binary, ".dcos.directory">>,
    convert_zone(ZoneName0, Records0, ?DCOS_DIRECTORY(""), NewPostfix).

%% For our usage postfix -> thisdcos.directory
%% New Postfix is $(zbase32(public_key).thisdcos.directory)
convert_zone(ZoneName0, Records0, Postfix, NewPostfix) ->
    ZoneName1 = convert_name(ZoneName0, Postfix, NewPostfix),
    Records1 = lists:filtermap(fun(Record) -> convert_record(Record, Postfix, NewPostfix) end, Records0),
    {ZoneName1, Records1}.

convert_name(Name, Postfix, NewPostfix) ->
    Size = size(Name) - size(Postfix),
    <<FrontName:Size/binary, Postfix/binary>> = Name,
    <<FrontName/binary, NewPostfix/binary>>.

convert_record(Record0 = #dns_rr{type = ?DNS_TYPE_A, name = Name0}, Postfix, NewPostfix) ->
    Name1 = convert_name(Name0, Postfix, NewPostfix),
    Record1 = Record0#dns_rr{name = Name1},
    {true, Record1};
convert_record(#dns_rr{
            type = ?DNS_TYPE_SRV, name = Name0,
            data = Data0 = #dns_rrdata_srv{target = Target0}
        } = Record0, Postfix, NewPostfix) ->
    Name1 = convert_name(Name0, Postfix, NewPostfix),
    Target1 = convert_name(Target0, Postfix, NewPostfix),
    Data1 = Data0#dns_rrdata_srv{target = Target1},
    Record1 = Record0#dns_rr{name = Name1, data = Data1},
    {true, Record1};
convert_record(Record0 = #dns_rr{name = Name0}, Postfix, NewPostfix) ->
    Name1 = convert_name(Name0, Postfix, NewPostfix),
    Record1 = Record0#dns_rr{name = Name1},
    {true, Record1}.

m_notify(ZoneName, Begin, Size) ->
    CompactZoneName = compact_zone_name(ZoneName),
    Name = binary:replace(CompactZoneName, <<".">>, <<"-">>, [global]),
    Ms = erlang:monotonic_time(millisecond) - Begin,
    folsom_metrics:notify({dns, zones, Name, records}, Size, gauge),
    folsom_metrics:notify({dns, zones, Name, updated}, {inc, 1}, counter),
    folsom_metrics:new_histogram(
        {dns, zones, Name, push_ms},
        slide_uniform, {?SLIDE_WINDOW, ?SLIDE_SIZE}),
    folsom_metrics:notify({dns, zones, Name, push_ms}, Ms, histogram).

compact_zone_name(ZoneName) ->
    case binary:split(ZoneName, ?DCOS_DIRECTORY("")) of
        [Name, <<>>] ->
            Name;
        [Name] ->
            Name
    end.

-spec(bin_to_hex(binary()) -> binary()).
bin_to_hex(Bin) ->
    Bin0 = << <<(integer_to_binary(N, 16))/binary>> || <<N:4>> <= Bin >>,
    cowboy_bstr:to_lower(Bin0).

-ifdef(TEST).
zone_convert_test() ->

    Records = [{dns_rr, <<"_framework._tcp.marathon.mesos.thisdcos.directory">>, 1,
        33, 5,
        {dns_rrdata_srv, 0, 0, 36241,
            <<"marathon.mesos.thisdcos.directory">>}},
        {dns_rr, <<"_leader._tcp.mesos.thisdcos.directory">>, 1, 33, 5,
            {dns_rrdata_srv, 0, 0, 5050,
                <<"leader.mesos.thisdcos.directory">>}},
        {dns_rr, <<"_leader._udp.mesos.thisdcos.directory">>, 1, 33, 5,
            {dns_rrdata_srv, 0, 0, 5050,
                <<"leader.mesos.thisdcos.directory">>}},
        {dns_rr, <<"_slave._tcp.mesos.thisdcos.directory">>, 1, 33, 5,
            {dns_rrdata_srv, 0, 0, 5051,
                <<"slave.mesos.thisdcos.directory">>}},
        {dns_rr, <<"leader.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"marathon.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"master.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"master0.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"mesos.thisdcos.directory">>, 1, 2, 3600,
            {dns_rrdata_ns, <<"ns.spartan">>}},
        {dns_rr, <<"mesos.thisdcos.directory">>, 1, 6, 3600,
            {dns_rrdata_soa, <<"ns.spartan">>,
                <<"support.mesosphere.com">>, 1, 60, 180, 86400,
                1}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {172, 17, 0, 1}}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {198, 51, 100, 1}}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {198, 51, 100, 2}}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {198, 51, 100, 3}}},
        {dns_rr, <<"slave.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 3, 101}}},
        {dns_rr, <<"slave.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 5, 155}}}],
    PublicKey = <<86, 39, 137, 9, 82, 47, 191, 138, 216, 134, 104, 152, 135, 11, 173, 38, 150, 107, 238, 7, 78,
        78, 17, 127, 194, 164, 28, 239, 31, 178, 219, 57>>,
    _SecretKey = <<243, 180, 170, 246, 243, 250, 151, 209, 107, 185, 80, 245, 39, 121, 7, 61, 151, 249, 79, 98,
        212, 191, 61, 252, 40, 107, 219, 230, 21, 215, 108, 98, 86, 39, 137, 9, 82, 47, 191, 138, 216,
        134, 104, 152, 135, 11, 173, 38, 150, 107, 238, 7, 78, 78, 17, 127, 194, 164, 28, 239, 31,
        178, 219, 57>>,
    PublicKeyEncoded = zbase32:encode(PublicKey),
    Postfix = <<"thisdcos.directory">>,
    NewPostfixA = <<PublicKeyEncoded/binary, <<".dcos.directory">>/binary>>,
    %NewPostfixA = <<PublicKeyEncoded/binary, <<".dcos.directory">>>>
    {NewName, NewRecords} = convert_zone(<<"mesos.thisdcos.directory">>, Records, Postfix, NewPostfixA),
    ExpectedName = <<"mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
    ?assertEqual(ExpectedName, NewName),
    ExpectedRecords =
        [
            {dns_rr,
            <<"_framework._tcp.marathon.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
            1, 33, 5,
            {dns_rrdata_srv, 0, 0, 36241,
                <<"marathon.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>}},
            {dns_rr, <<"_leader._tcp.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 33, 5,
                {dns_rrdata_srv, 0, 0, 5050,
                    <<"leader.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>}},
            {dns_rr, <<"_leader._udp.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 33, 5,
                {dns_rrdata_srv, 0, 0, 5050,
                    <<"leader.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>}},
            {dns_rr, <<"_slave._tcp.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 33, 5,
                {dns_rrdata_srv, 0, 0, 5051,
                    <<"slave.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>}},
            {dns_rr, <<"leader.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"marathon.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"master.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"master0.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>, 1, 2, 3600,
                {dns_rrdata_ns, <<"ns.spartan">>}},
            {dns_rr, <<"mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>, 1, 6, 3600,
                {dns_rrdata_soa, <<"ns.spartan">>,
                    <<"support.mesosphere.com">>, 1, 60, 180, 86400,
                    1}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {172, 17, 0, 1}}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {198, 51, 100, 1}}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {198, 51, 100, 2}}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {198, 51, 100, 3}}},
            {dns_rr, <<"slave.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 3, 101}}},
            {dns_rr, <<"slave.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 5, 155}}}],
    ?assertEqual(ExpectedRecords, NewRecords).
-endif.
