%%% @doc Track an RPC client endpoint
%%% This supervisor will maintain an AMQP Rpc client endpoint and keep it running
%%% @end
-module(amqp_client_sup).

-behaviour(supervisor).

-include_lib("amqp_client/include/amqp_client.hrl").

%% API
-export([start_link/4]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================

%% @doc Start up a client supervisor.
%% There are the following parameters:
%%
%% <ul>
%% <li>Endpoint: The registered name for this endpoint. Use amqp_rpc_client2:call(Endpoint, Msg).</li>
%% <li>ConnReg: The registered name of the connection handler.</li>
%% <li>ConnInfo: The #amqp_params_network{} record to use as the connection base.</li>
%% <li>RoutingKey: The routing key to use.</li>
%% </ul>
%% @end
-spec start_link(EndPoint, ConnReg, ConnInfo, ClientConfig) -> {ok, pid()}
  when EndPoint :: atom(),
       ConnReg :: atom(),
       ConnInfo :: #amqp_params_network{},
       ClientConfig :: list({atom(), term()}).
start_link(EndPoint, ConnReg, ConnInfo, ClientConfig) ->
    supervisor:start_link(?MODULE, [EndPoint, ConnReg, ConnInfo, ClientConfig]).

%% ===================================================================

init([EndPoint, ConnReg, ConnInfo, ClientConfig]) ->
	Connection = {connection, {amqp_connection_mgr, start_link, [ConnReg, ConnInfo]},
	               permanent, 5000, worker, [amqp_connection_mgr]},
	Client = {client, {amqp_rpc_client2, start_link, [EndPoint, ClientConfig , ConnReg]},
	           permanent, 5000, worker, [amqp_rpc_client2]},
	%% 10 times in an hour is the current death rate which is allowed.
    {ok, { {one_for_all, 10, 3600}, [Connection, Client]} }.
