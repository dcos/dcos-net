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
-define(SPARTAN_RETRY, 30000).

-include("dcos_dns.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("dns/include/dns.hrl").


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    {ok, Ref} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({[navstar, dns, zones, '_']}) -> true end)),
    {ok, #state{ref = Ref}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info({lashup_kv_events, Event = #{ref := Reference}}, State = #state{ref = Ref}) when Ref == Reference ->
    handle_event(Event),
    {noreply, State};
handle_info({retry_spartan, Key}, State) ->
    retry_spartan(Key),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

spartan_name() ->
    [_Node, Host] = binary:split(atom_to_binary(node(), utf8), <<"@">>),
    SpartanBinName = <<"spartan@", Host/binary>>,
    binary_to_atom(SpartanBinName, utf8).

zone2spartan(ZoneName, LashupValue) ->
    {_, Records} = lists:keyfind(?RECORDS_FIELD, 1, LashupValue),
    Sha = crypto:hash(sha, term_to_binary(Records)),
    {ZoneName, Sha, Records}.

handle_event(_Event = #{key := [navstar, dns, zones, ZoneName], value := Value}) ->
    Zone = zone2spartan(ZoneName, Value),
    spartan_push(Zone).

retry_spartan(Key = [navstar, dns, zones, ZoneName]) ->
    Value = lashup_kv:value(Key),
    Zone = zone2spartan(ZoneName, Value),
    spartan_push(Zone).

spartan_push(Zone = {ZoneName, _, _}) ->
    case rpc:call(spartan_name(), erldns_zone_cache, put_zone, [Zone], ?RPC_TIMEOUT) of
        Reason = {badrpc, _} ->
            lager:warning("Unable to push records to spartan: ~p", [Reason]),
            setup_retry(ZoneName),
            ok;
        ok ->
            maybe_push_signed_zone(Zone),
            ok
    end.

setup_retry(ZoneName) ->
    {ok, _} = timer:send_after(?SPARTAN_RETRY, {retry_spartan, [navstar, dns, zones, ZoneName]}).


maybe_push_signed_zone(Zone) ->
    case dcos_dns:key() of
        false ->
            ok;
        #{public_key := PublicKey} ->

            push_signed_zone(PublicKey, Zone)
    end.

push_signed_zone(PublicKey, _Zone0 = {ZoneName0, _ZoneSha, Records0}) ->
    {ZoneName1, Records1} = convert_zone(PublicKey, ZoneName0, Records0),
    Sha = crypto:hash(sha, term_to_binary(Records1)),
    Zone1 = {ZoneName1, Sha, Records1},
    case rpc:call(spartan_name(), erldns_zone_cache, put_zone, [Zone1], ?RPC_TIMEOUT) of
        Reason = {badrpc, _} ->
            lager:warning("Unable to push signed records to spartan: ~p", [Reason]),
            setup_retry(ZoneName0),
            ok;
        ok ->
            ok
    end.


convert_zone(PublicKey, ZoneName0, Records0) ->
    PublicKeyEncoded = zbase32:encode(PublicKey),
    NewPostfix = <<PublicKeyEncoded/binary, <<".dcos.directory">>/binary>>,
    convert_zone(ZoneName0, Records0, ?POSTFIX, NewPostfix).

%% For our usage postfix -> thisdcos.directory
%% New Postfix is $(zbase32(public_key).thisdcos.directory)
convert_zone(ZoneName0, Records0, Postfix, NewPostfix) ->
    ZoneName1 = convert_name(ZoneName0, Postfix, NewPostfix),
    Records1 = lists:filtermap(fun(Record) -> convert_record(Record, Postfix, NewPostfix) end, Records0),
    {ZoneName1, Records1}.

convert_name(Name, Postfix, NewPostfix) ->
    true = size(Postfix) == binary:longest_common_suffix([Name, Postfix]),
    FrontName = binary:part(Name, 0, size(Name) - size(Postfix)),
    <<FrontName/binary, NewPostfix/binary>>.


convert_record(Record0 = #dns_rr{type = ?DNS_TYPE_A, name = Name0}, Postfix, NewPostfix) ->
    Name1 = convert_name(Name0, Postfix, NewPostfix),
    Record1 = Record0#dns_rr{name = Name1},
    {true, Record1};


convert_record(Record0 = #dns_rr{type = ?DNS_TYPE_SRV, name = Name0, data = Data0 = #dns_rrdata_srv{target = Target0}},
        Postfix, NewPostfix) ->
    Name1 = convert_name(Name0, Postfix, NewPostfix),
    Target1 = convert_name(Target0, Postfix, NewPostfix),
    Data1 = Data0#dns_rrdata_srv{target = Target1},
    Record1 = Record0#dns_rr{name = Name1, data = Data1},
    {true, Record1};
convert_record(_, _, _) ->
    false.




-ifdef(TEST).
zone_convert_test() ->

    Records =[{dns_rr,<<"_framework._tcp.marathon.mesos.thisdcos.directory">>,1,
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
            {dns_rrdata_a,{10,0,5,155}}}],
    PublicKey = <<86,39,137,9,82,47,191,138,216,134,104,152,135,11,173,38,150,107,238,7,78,
        78,17,127,194,164,28,239,31,178,219,57>>,
    _SecretKey = <<243,180,170,246,243,250,151,209,107,185,80,245,39,121,7,61,151,249,79,98,
            212,191,61,252,40,107,219,230,21,215,108,98,86,39,137,9,82,47,191,138,216,
            134,104,152,135,11,173,38,150,107,238,7,78,78,17,127,194,164,28,239,31,
            178,219,57>>,
    PublicKeyEncoded = zbase32:encode(PublicKey),
    Postfix = <<"thisdcos.directory">>,
    NewPostfixA = <<PublicKeyEncoded/binary, <<".dcos.directory">>/binary>>,
    %NewPostfixA = <<PublicKeyEncoded/binary, <<".dcos.directory">>>>
    {NewName, NewRecords} = convert_zone(<<"mesos.thisdcos.directory">>, Records, Postfix, NewPostfixA),
    ?debugFmt("new name: ~p", [NewName]),
    ?debugFmt("new records: ~p", [NewRecords]).
-endif.