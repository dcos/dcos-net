-module(dcos_dns_SUITE).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

%% common_test callbacks
-export([%% suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0]).

%% tests
-export([
         upstream_test/1,
         zk_test/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-define(CONFIG, "../../../../config/sys.config").

%% ===================================================================
%% common_test callbacks
%% ===================================================================

init_per_suite(_Config) ->
    application:load(erldns),
    {ok, [Terms]} = file:consult(?CONFIG),
    lists:foreach(fun({App, Environment}) ->
                        lists:foreach(fun({Par, Val}) ->
                                            ok = application:set_env(App, Par, Val)
                        end, Environment)
                  end, Terms),
    application:ensure_all_started(dcos_dns),
    _Config.

end_per_suite(_Config) ->
    _Config.

init_per_testcase(_Case, _Config) ->
    _Config.

end_per_testcase(_, _Config) ->
    ok.

all() ->
    [
     upstream_test,
     zk_test
    ].

%% ===================================================================
%% tests
%% ===================================================================

%% @doc Assert an upstream request is resolved by the dual dispatch FSM.
upstream_test(_Config) ->
    {ok, DnsMsg} = inet_res:resolve("www.google.com", in, a, resolver_options()),
    Answers = inet_dns:msg(DnsMsg, anlist),
    ?assert(length(Answers) > 0),
    ok.

%% @doc Assert we can resolve the Zookeeper records.
zk_test(_Config) ->
    {ok, DnsMsg} = inet_res:resolve("1.zk", in, a, resolver_options()),
    [Answer] = inet_dns:msg(DnsMsg, anlist),
    Data = inet_dns:rr(Answer, data),
    ?assertMatch({10,0,4,160}, Data),
    ok.

%% @private
%% @doc Use the dcos_dns resolver.
resolver_options() ->
    [{nameservers, [{{127,0,0,1}, 8053}]}].
