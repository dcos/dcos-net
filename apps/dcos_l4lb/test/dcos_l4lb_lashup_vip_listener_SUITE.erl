-module(dcos_l4lb_lashup_vip_listener_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("dcos_l4lb.hrl").

-export([
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2,
    test_uninitalized_table/1,
    lookup_vip/1,
    lookup_failure/1,
    lookup_failure2/1,
    lookup_failure3/1
]).


%% root tests
all() ->
  [test_uninitalized_table,
   lookup_vip,
   lookup_failure,
   lookup_failure2,
   lookup_failure3].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(test_uninitalized_table, Config) -> Config;
init_per_testcase(_, Config) ->
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    Config.

end_per_testcase(test_uninitalized_table, _Config) -> ok;
end_per_testcase(_, _Config) ->
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    ok.

test_uninitalized_table(_Config) ->
  IP = {10, 0, 1, 10},
  [] = dcos_l4lb_lashup_vip_listener:lookup_vips([{ip, IP}]),
  ok.

lookup_failure(_Config) ->
  IP = {10, 0, 1, 10},
  [{badmatch, IP}] = dcos_l4lb_lashup_vip_listener:lookup_vips([{ip, IP}]),
  Name = <<"foobar.marathon">>,
  [{badmatch, Name}] = dcos_l4lb_lashup_vip_listener:lookup_vips([{name, Name}]),
  ok.

lookup_failure2(Config) ->
  {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{update,
                                                       {{tcp, {1, 2, 3, 4}, 5000}, riak_dt_orswot},
                                                       {add, {{10, 0, 1, 10}, {{10, 0, 1, 10}, 17780}}}}]}),
  lookup_failure(Config),
  ok.

lookup_failure3(Config) ->
  {ok, _} = update_de8b9dc86_marathon(),
  lookup_failure(Config),
  ok.

lookup_vip(_Config) ->
  {ok, _} = update_de8b9dc86_marathon(),
  [] = dcos_l4lb_lashup_vip_listener:lookup_vips([]),
  [{ip, IP}] = dcos_l4lb_lashup_vip_listener:lookup_vips([{name, <<"de8b9dc86.marathon">>}]),
  [{name, <<"de8b9dc86.marathon">>}] = dcos_l4lb_lashup_vip_listener:lookup_vips([{ip, IP}]),
  ok.

update_de8b9dc86_marathon() ->
  lashup_kv:request_op(?VIPS_KEY2, {update, [{update,
    {{tcp, {name, {<<"de8b9dc86">>, <<"marathon">>}}, 6000}, riak_dt_orswot},
    {add, {{10, 0, 1, 31}, {{10, 0, 1, 31}, 12998}}}
  }]}).
