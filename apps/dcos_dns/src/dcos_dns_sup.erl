-module(dcos_dns_sup).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    ZkRecordServer = {dcos_dns_zk_record_server,
                      {dcos_dns_zk_record_server, start_link, []},
                       permanent, 5000, worker,
                       [dcos_dns_zk_record_server]},

    DispatchFsm = {dcos_dns_dns_dual_dispatch_fsm_sup,
                   {dcos_dns_dns_dual_dispatch_fsm_sup, start_link, []},
                    permanent, infinity, supervisor,
                    [dcos_dns_dns_dual_dispatch_fsm_sup]},

    {ok, { {one_for_all, 0, 1}, [ZkRecordServer, DispatchFsm]} }.

%%====================================================================
%% Internal functions
%%====================================================================
