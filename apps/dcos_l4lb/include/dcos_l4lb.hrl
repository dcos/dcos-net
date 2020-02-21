-define(VIPS_KEY2, [minuteman, vips2]).

-record(netns, {id :: undefined | term(),
                ns :: undefined | binary()}).
-type netns() :: #netns{}.

-define(L4LB_ZONE_NAME, [<<"l4lb">>, <<"thisdcos">>, <<"directory">>]).
