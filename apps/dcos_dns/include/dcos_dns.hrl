-define(APP, dcos_dns).
-define(TLD, "zk").
-define(ERLDNS_HANDLER, dcos_dns_erldns_handler).

-define(COUNTER, counter).
-define(HISTOGRAM, histogram).
-define(SPIRAL, spiral).
-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_CONNECT_TIMEOUT, 30000).

-type upstream() :: {inet:ip4_address(), inet:port_number()}.
