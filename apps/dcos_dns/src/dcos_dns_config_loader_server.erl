%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. Mar 2016 1:37 PM
%%%-------------------------------------------------------------------
-module(dcos_dns_config_loader_server).
-author("sdhillon").

-behaviour(gen_server).


%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

%% API
-export([start_link/0, start_link/1]).

-include("dcos_dns.hrl").

-define(REFRESH_INTERVAL_NORMAL, 120000).
-define(REFRESH_INTERVAL_FAIL, 5000).
-define(REFRESH_MESSAGE,  refresh).
-define(MESOS_DNS_PORT, 61053).


%% State record.
-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    start_link([]).

%% @doc Start and link to calling process.
-spec start_link(list())-> {ok, pid()} | ignore | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).


%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    timer:send_after(0, ?REFRESH_MESSAGE),
    {ok, #state{}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.

%% @private
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(?REFRESH_MESSAGE, State) ->
    NormalRefreshInterval = application:get_env(?APP, masters_refresh_interval_normal, ?REFRESH_INTERVAL_NORMAL),
    FailRefreshInterval = application:get_env(?APP, masters_refresh_interval_fail, ?REFRESH_INTERVAL_FAIL),
    case maybe_load_masters() of
        ok ->
            {ok, _} = timer:send_after(NormalRefreshInterval, ?REFRESH_MESSAGE);
        error ->
            {ok, _} = timer:send_after(FailRefreshInterval, ?REFRESH_MESSAGE)
    end,
    {noreply, State};
handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%%%===================================================================
%%% Internal functions
%%%===================================================================
%%%% Algorithm copied from gen_resolv
maybe_load_masters() ->
    case get_masters() of
        {ok, Masters} ->
            application:set_env(?APP, mesos_resolvers, Masters),
            ok;
        {error, _} ->
            error
    end.

get_masters() ->
    case os:getenv("MASTER_SOURCE") of
        "exhibitor" ->
            get_masters_exhibitor();
        "master_list" ->
            get_masters_file();
        Source ->
            lager:warning("Unable to load masters (dcos_dns) from source: ~p", [Source]),
            {error, bad_source}
    end.

get_masters_file() ->
    {ok, FileBin} = file:read_file("/opt/mesosphere/etc/master_list"),
    MastersBinIPs = jsx:decode(FileBin, [return_maps]),
    IPAddresses = lists:map(fun dcos_dns_app:parse_ipv4_address/1, MastersBinIPs),
    {ok, [{IPAddress, ?MESOS_DNS_PORT} || IPAddress <- IPAddresses]}.

get_masters_exhibitor() ->
    ExhibitorAddress = os:getenv("EXHIBITOR_ADDRESS"),
    Url = lists:flatten(io_lib:format("http://~s:8181/exhibitor/v1/cluster/status", [ExhibitorAddress])),
    case httpc:request(get, {Url, []}, [], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            ExhibitorStatuses = jsx:decode(Body, [return_maps]),
            ExhibitorHostnames = [Hostname || #{<<"hostname">> := Hostname} <- ExhibitorStatuses],
            IPAddresses = lists:map(fun dcos_dns_app:parse_ipv4_address/1, ExhibitorHostnames),
            {ok, [{IPAddress, ?MESOS_DNS_PORT} || IPAddress <- IPAddresses]};
        Error ->
            lager:info("Failed to retrieve information from exhibitor to configure dcos_dns: ~p", [Error]),
            {error, unavailable}
    end.

