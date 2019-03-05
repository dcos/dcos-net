-module(dcos_net_utils_tests).
-include_lib("eunit/include/eunit.hrl").

complement_test() ->
    {A, B} =
        dcos_net_utils:complement(
          [a, 0, b, 1, c, 2],
          [e, 0, d, 1, f, 2]),
    ?assertEqual(
       {[a, b, c], [d, e, f]},
       {lists:sort(A), lists:sort(B)}).

system_test() ->
    case dcos_net_utils:system([<<"/bin/pwd">>]) of
        {error, enoent} -> ok;
        {ok, Pwd} ->
            {ok, Cwd} = file:get_cwd(),
            ?assertEqual(iolist_to_binary([Cwd, "\n"]), Pwd)
    end.

system_timeout_test() ->
    case dcos_net_utils:system([<<"/bin/dd">>], 100) of
        {error, enoent} -> ok;
        {error, timeout} -> ok
    end.

join_empty_bin_test_() -> [
    ?_assertEqual(
       <<>>,
       dcos_net_utils:join([], <<"no">>)),
    ?_assertEqual(
       <<>>,
       dcos_net_utils:join([], <<>>)),
    ?_assertEqual(
       <<>>,
       dcos_net_utils:join([<<>>], <<>>)),
    ?_assertEqual(
       <<"a">>,
       dcos_net_utils:join([<<"a">>], <<>>)),
    ?_assertEqual(
       <<"ab">>,
       dcos_net_utils:join([<<"a">>, <<"b">>], <<>>)),
    ?_assertEqual(
       <<"yes">>,
       dcos_net_utils:join([<<>>, <<>>], <<"yes">>))
].

join_basic_test_() -> [
    ?_assertEqual(
       <<"foo">>,
       dcos_net_utils:join([<<"foo">>], <<".">>)),
    ?_assertEqual(
       <<"foo.bar">>,
       dcos_net_utils:join([<<"foo">>, <<"bar">>], <<".">>)),
    ?_assertEqual(
       <<"foo...bar">>,
       dcos_net_utils:join([<<"foo">>, <<"bar">>], <<"...">>)),
    ?_assertEqual(
       <<"foo。bar">>,
       dcos_net_utils:join([<<"foo">>, <<"bar">>], <<"。">>)),
    ?_assertEqual(
       <<"foo.bar.">>,
       dcos_net_utils:join([<<"foo">>, <<"bar">>, <<>>], <<".">>))
].
