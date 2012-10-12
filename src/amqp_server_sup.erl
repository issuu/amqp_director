%%% @doc Keep track of an AMQP connection endpoint
%%%
%%% This module is a supervisor for the infrastructure which keeps track of
%%% a pool of AMQP server endpoints together with an AMQP connection. In effect,
%%% you supply a count of how many workers you want in the pool. Each worker is 
%%% given a function to execute. Whenever there are messages on the queue, this 
%%% function will be called.
%%% @end
-module(amqp_server_sup).

-behaviour(supervisor).

%% API
-export([start_link/6]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
%% ===================================================================
%% @doc Start the supervisor.
%% The parameters are as in `amqp_server_pool_sup' except for `RegName'
%% which supplies an atom() under which to register the connection for this
%% tree.
%% @end
start_link(RegName, ConnInfo, ListenQueue, LQArgs, Fun, Count) ->
    supervisor:start_link(?MODULE, [RegName, ConnInfo, ListenQueue, LQArgs, Fun, Count]).

%% ===================================================================
init([RegName, ConnInfo, ListenQueue, LQArgs, Fun, Count]) ->
    Connection = {connection, {amqp_connection_mgr, start_link, [RegName, ConnInfo]},
                   permanent, 5000, worker, [amqp_connection_mgr]},
    ServerSup = {server_sup, {amqp_server_pool_sup, start_link, [RegName, ListenQueue, LQArgs, Fun, Count]},
                   transient, infinity, supervisor, [amqp_server_pool_sup]},
    {ok, { {one_for_all, 10, 3600}, [Connection, ServerSup]} }.
