-define(NODEMETADATA_KEY, [minuteman, nodemetadata, ip]).

-define(LWW_REG(Value), {Value, riak_dt_lwwreg}).

-define(KUBEMETADATA_KEY, [minuteman, kubemetadata, apiserver]).

-define(KUBEAPIKEY, <<"apiserver.kubernetes">>).
