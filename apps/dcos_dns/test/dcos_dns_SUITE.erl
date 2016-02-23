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
-export([upstream_test/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

%% ===================================================================
%% common_test callbacks
%% ===================================================================

init_per_suite(_Config) ->
    application:load(erldns),
    {ok, [Terms]} = file:consult("../../../../config/sys.config"),
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
     upstream_test
    ].

%% ===================================================================
%% tests
%% ===================================================================

%% @doc Assert an upstream request is resolved by the dual dispatch FSM.
upstream_test(_Config) ->
    Name = "www.google.com",
    Class = in,
    Type = a,
    Nameserver = {{127,0,0,1}, 8053},
    Options = [{nameservers, [Nameserver]}],
    {ok, DnsMsg} = inet_res:resolve(Name, Class, Type, Options),
    Answers = inet_dns:msg(DnsMsg, anlist),
    ?assert(length(Answers) > 0),
    ok.
