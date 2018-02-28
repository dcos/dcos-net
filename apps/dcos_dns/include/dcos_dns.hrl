-define(APP, dcos_dns).
-define(TLD, "zk").
-define(ERLDNS_HANDLER, dcos_dns_erldns_handler).

-define(COUNTER, counter).
-define(HISTOGRAM, histogram).
-define(SPIRAL, spiral).

-type upstream() :: {inet:ip4_address(), inet:port_number()}.

-define(LASHUP_KEY(ZoneName), [navstar, dns, zones, ZoneName]).
-define(RECORDS_FIELD, {records, riak_dt_orswot}).
-define(DCOS_DIRECTORY(Prefix), <<Prefix, ".thisdcos.directory">>).
-define(DCOS_DOMAIN, ?DCOS_DIRECTORY("dcos.")).

%% 30 seconds
-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_CONNECT_TIMEOUT, 30000).
-define(EXHIBITOR_TIMEOUT, 30000).
