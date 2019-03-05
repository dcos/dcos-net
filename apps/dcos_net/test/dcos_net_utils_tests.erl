-module(dcos_net_utils_tests).
-include_lib("eunit/include/eunit.hrl").

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
