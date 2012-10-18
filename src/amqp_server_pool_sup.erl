%%% @doc Keep track of a pool of AMQP server endpoints
%%%
%%% This supervisor handles a server pool of static size. It boots
%%% a number of RPC Server workers and sets them up for handling work
%%% on the pool. It is intended to be used to scale out a static worker
%%% pool of processes so you can get the concurrency level up.
%%% @end
-module(amqp_server_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/4]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================

%% @doc Start the supervisor with a static WorkerCount
%% The parameters are as in amqp_rpc_server2, except for the last one
%% which is the number of workers we desire.
%% @end
-spec start_link(ConnectionRef, Config, Fun, WorkerCount) -> {ok, pid()}
  when ConnectionRef :: pid(),
       Config :: list({atom(), term()}),
       Fun :: fun ((binary()) -> {reply, binary()} | ack | reject | reject_no_requeue),
       WorkerCount :: pos_integer().
start_link(ConnectionRef, Config, Fun, WorkerCount) ->
    supervisor:start_link(?MODULE, [ConnectionRef, Config, Fun, WorkerCount]).

%% ===================================================================
init([ConnectionRef, Config, Fun, WorkerCount]) ->
    %% The given servers are named as atoms '1' to '20'. It has to be an atom here, you can not use
    %% an arbitrary term.
    ServerPool = [{list_to_atom(integer_to_list(N)), {amqp_rpc_server2, start_link,
                                                      [ConnectionRef, Config, Fun]},
                     permanent, 5000, worker, [amqp_rpc_server2]}
                  || N <- lists:seq(1, WorkerCount)],
    {ok, { {one_for_one, 10, 3600}, ServerPool } }.
