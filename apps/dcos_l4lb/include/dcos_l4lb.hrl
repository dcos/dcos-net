-define(VIPS_KEY2, [minuteman, vips2]).

-record(netns, {id :: undefined | term(),
                ns :: undefined | binary()}).

-define(ZONE_NAMES, [
    [<<"l4lb">>, <<"thisdcos">>, <<"directory">>],
    [<<"l4lb">>, <<"thisdcos">>, <<"global">>],
    [<<"dclb">>, <<"thisdcos">>, <<"directory">>],
    [<<"dclb">>, <<"thisdcos">>, <<"global">>]
]).
