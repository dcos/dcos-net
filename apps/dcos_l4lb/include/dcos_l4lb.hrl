-define(VIPS_KEY2, [minuteman, vips2]).
-define(VIPS_KEY3, [l4lb, vips]).
-define(VIPS_FIELD, {vips, riak_dt_lwwreg}).

-record(netns, {id :: undefined | term(),
                ns :: undefined | binary()}).
-type netns() :: #netns{}.

-define(L4LB_ZONE_NAME, [<<"l4lb">>, <<"thisdcos">>, <<"directory">>]).
