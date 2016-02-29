-module(dcos_dns_dns_dual_dispatch_fsm).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/5,
         resolve/3,
         async_resolve/4,
         async_resolve/5,
         sync_resolve/3]).

%% gen_fsm callbacks
-export([init/1,
         execute/2,
         waiting/2,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-define(SERVER, ?MODULE).

-include("dcos_dns.hrl").

%% We can't include these because of name clashes.
% -include_lib("kernel/src/inet_dns.hrl").
% -include_lib("kernel/src/inet_res.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-record(state, {id :: dns:message_id(),
                req_id :: req_id(),
                from :: pid(),
                message :: dns:message(),
                authority_records :: [dns:rr()],
                host :: dns:ip(),
                self :: pid(),
                name :: dns_query:name(),
                type :: dns_query:type(),
                class :: dns_query:class()
               }).

-type error()      :: term().
-type req_id()     :: term().

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(req_id(), pid(), dns:message(), [dns:rr()], dns:ip()) -> {ok, pid()} | ignore | {error, error()}.
start_link(ReqId, From, Message, AuthorityRecords, Host) ->
    gen_fsm:start_link(?MODULE,
                       [ReqId, From, Message, AuthorityRecords, Host],
                       []).

-spec resolve(dns:message(), [dns:rr()], dns:ip()) -> {ok, req_id()}.
resolve(Message, AuthorityRecords, Host) ->
    ReqId = mk_reqid(),
    _ = dcos_dns_dns_dual_dispatch_fsm_sup:start_child(
            [ReqId, self(), Message, AuthorityRecords, Host]),
    {ok, ReqId}.

-spec sync_resolve(dns:message(), [dns:rr()], dns:ip()) -> {ok, dns:message()}.
sync_resolve(Message, AuthorityRecords, Host) ->
    ReqId = mk_reqid(),
    _ = dcos_dns_dns_dual_dispatch_fsm_sup:start_child(
            [ReqId, self(), Message, AuthorityRecords, Host]),
    dcos_dns_app:wait_for_reqid(ReqId, infinity).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%% @private
init([ReqId, From, Message, AuthorityRecords, Host]) ->
    lager:info("Resolution request for message: ~p", [Message]),
    Self = self(),
    Id = Message#dns_message.id,
    Questions = Message#dns_message.questions,
    Question = hd(Questions),
    Name = Question#dns_query.name,
    Type = Question#dns_query.type,
    Class = Question#dns_query.class,
    lager:info("Question: ~p", [Question]),
    {ok, execute, #state{id=Id,
                         req_id=ReqId,
                         from=From,
                         message=Message,
                         authority_records=AuthorityRecords,
                         host=Host,
                         self=Self,
                         name=Name,
                         type=Type,
                         class=Class}, 0}.

%% @doc Dispatch to all resolvers.
execute(timeout, #state{self=Self,
                        name=Name,
                        class=Class,
                        type=Type,
                        message=Message,
                        authority_records=AuthorityRecords,
                        host=Host}=State) ->
    Name = normalize_name(Name),
    case dns:dname_to_labels(Name) of
      [] ->
            gen_fsm:send_event(Self, {error, zone_not_found});
      [_] ->
            gen_fsm:send_event(Self, {error, zone_not_found});
      [_|Labels] ->
            case Labels of
                [<<"zk">>] ->
                    %% Zookeeper request.
                    zookeeper_resolve(Self, Message, AuthorityRecords, Host);
                [<<"mesos">>] ->
                    mesos_resolve(Self, Name, Class, Type, Message, AuthorityRecords, Host);
                _ ->
                    %% Upstream request.
                    upstream_resolve(Self, Name, Class, Type)
            end
    end,
    {next_state, waiting, State}.

%% @doc Return as soon as we receive the first response.
waiting(Response, #state{id=Id, req_id=ReqId, from=From}=State) ->
    lager:info("Received response: ~p", [Response]),
    From ! {ReqId, ok, dcos_dns_dns_converter:convert_message(Response, Id)},
    {stop, normal, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
normalize_name(Name) when is_list(Name) ->
    string:to_lower(Name);
normalize_name(Name) when is_binary(Name) ->
    list_to_binary(string:to_lower(binary_to_list(Name))).

%% @private
%% @doc Internal callback function for performing local resolution.
async_resolve(Self, Message, AuthorityRecords, Host) ->
    Response = erldns_resolver:resolve(Message, AuthorityRecords, Host),
    gen_fsm:send_event(Self, Response).

%% @private
%% @doc Internal callback function for performing resolution.
async_resolve(Self, Name, Class, Type, Resolver) ->
    {ok, IpAddress} = inet:parse_address(Resolver),
    Opts = [{nameservers, [{IpAddress, ?PORT}]}],

    %% @todo It's unclear how to return a nxdomain response through
    %%       erldns, yet.  Figure it out.
    {ok, Response} = inet_res:resolve(binary_to_list(Name), Class, Type, Opts),

    gen_fsm:send_event(Self, Response).

%% @doc Generate a request id.
mk_reqid() ->
    erlang:phash2(erlang:timestamp()).

%% @private
upstream_resolve(Self, Name, Class, Type) ->
    [spawn(?MODULE, async_resolve, [Self, Name, Class, Type, Resolver])
     || Resolver <- ?UPSTREAM_RESOLVERS].

%% @private
zookeeper_resolve(Self, Message, AuthorityRecords, Host) ->
    spawn(?MODULE, async_resolve, [Self, Message, AuthorityRecords, Host]).

-ifdef(TEST).

mesos_resolve(Self, _Name, _Class, _Type, Message, AuthorityRecords, Host) ->
    spawn(?MODULE, async_resolve, [Self, Message, AuthorityRecords, Host]).

-else.

%% @private
mesos_resolve(Self, Name, Class, Type, _Message, _AuthorityRecords, _Host) ->
    [spawn(?MODULE, async_resolve, [Self, Name, Class, Type, Resolver])
     || Resolver <- ?MESOS_RESOLVERS].

-endif.

-ifdef(TEST).

%% @doc Generate a question for resolving.
create_question_message(Domain) when is_binary(Domain) ->
    #dns_message{id=23351,
                 qr=false,
                 oc=0,
                 aa=false,
                 tc=false,
                 rd=true,
                 ra=false,
                 ad=false,
                 cd=false,
                 rc=0,
                 qc=1,
                 anc=0,
                 auc=0,
                 adc=0,
                 questions=[{dns_query, Domain, 1, 1}],
                 answers=[],
                 authority=[],
                 additional=[]}.
%% @doc Verify upstream resolution works.
%%      Given we don't know what Google will resolve to at any one point
%%      or how many records are returned, just verify that we get an
%%      answer from upstream and that the conversion of records is
%%      successful.
upstream_resolve_test() ->
    Domain = <<"www.google.com">>,
    ReqId = mk_reqid(),
    From = self(),
    Message = create_question_message(Domain),
    AuthorityRecords = [],
    Host = undefined,
    {ok, _Pid} = ?MODULE:start_link(ReqId, From, Message, AuthorityRecords, Host),
    Response = dcos_dns_app:wait_for_reqid(ReqId, 10000),
    ?assertMatch({ok, #dns_message{}}, Response),
    {ok, #dns_message{answers=Answers}} = Response,
    ?assert(length(Answers) > 0),
    ok.

-endif.
