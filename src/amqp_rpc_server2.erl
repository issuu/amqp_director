%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2012 VMware, Inc.  All rights reserved.
%%

%% @doc This is a utility module that is used to expose an arbitrary function
%% via an asynchronous RPC over AMQP mechanism. It frees the implementor of
%% a simple function from having to plumb this into AMQP. Note that the
%% RPC server does not handle any data encoding, so it is up to the callback
%% function to marshall and unmarshall message payloads accordingly.
%%
%% The original RabbitMQ code by VMware has been altered to handle certain
%% kinds of errors and to fit into a supervisor tree of a hosting application.
%% Thus the intention is to embed server workers like these in the host application
%% supervisor tree.
%% @end
-module(amqp_rpc_server2).

-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export([start_link/4]).

-record(state, {channel, handler}).
-define(MAX_RECONNECT, timer:seconds(30)).

%%--------------------------------------------------------------------------

%% @doc Starts a new RPC server instance that receives requests via a
%% specified queue and dispatches them to a specified handler function. You
%% need to supply a connection reference to a `connection_mgr' process as well
%% as the queue you want to listen on. Since the queue will be created if it
%% does not already exist (and checked if it does), you also need to supply
%% queue arguments. Currently in the RabbitMQ native format. There is no provision
%% for marking queues as durable at the moment.
%%
%% The function can return different kinds of messages depending on what it
%% wants the server to do with the connection. You can either reply, ack, reject
%% or finally reject the request with no requeueing.
%% @end
-type amqp_queue_args() :: list({binary(), atom(), term()}).
-spec start_link(ConnectionRef, Queue, QueueArgs, RpcHandler) -> {ok, pid()}
  when ConnectionRef :: pid(),
       Queue :: binary(),
       QueueArgs :: amqp_queue_args(),
       RpcHandler :: fun ((binary()) -> {reply, binary()} | ack | reject | reject_no_requeue).
start_link(ConnectionRef, Queue, QueueArgs, Fun) ->
    gen_server:start_link(?MODULE, [ConnectionRef, Queue, QueueArgs, Fun], []).

%%--------------------------------------------------------------------------

%% @private
init([ConnectionRef, Q, QArgs, Fun]) ->
	{ok, try_connect(ConnectionRef, Q, QArgs, Fun, 1000)}.
      
%% @private
handle_info(shutdown, State) ->
    {stop, normal, State};

%% @private
handle_info({reconnect, CRef, Q, QArgs, Fun, ReconnectTime}, #state { channel = undefined }) ->
	error_logger:info_report([trying_to_reconnect]),
    {noreply, try_connect(CRef, Q, QArgs, Fun, ReconnectTime)};
handle_info({#'basic.consume'{}, _}, State) ->
    {noreply, State};
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};
handle_info(#'basic.cancel'{}, State) ->
    {step, amqp_server_cancelled, State};
handle_info(#'basic.cancel_ok'{}, State) ->
    {stop, normal, State};
handle_info({#'basic.deliver'{delivery_tag = DeliveryTag},
             #amqp_msg{props = Props, payload = Payload}},
            State = #state{handler = Fun, channel = Channel}) ->
    #'P_basic'{correlation_id = CorrelationId,
               content_type = ContentType,
               type = Type,
               reply_to = Q} = Props,
    case Fun(Payload, ContentType, Type) of
      {reply, Response, CT} ->
        Properties = #'P_basic'{correlation_id = CorrelationId,
                                content_type = CT,
                                type = <<"reply">>},
        Publish = #'basic.publish'{exchange = <<>>,
                                   routing_key = Q,
                                   mandatory = true},
        amqp_channel:call(Channel, Publish, #amqp_msg{props = Properties,
                                                      payload = Response}),
        amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DeliveryTag}),
        {noreply, State};
      reject ->
        amqp_channel:call(Channel, #'basic.reject'{delivery_tag = DeliveryTag, requeue = true}),
        {noreply, State};
      reject_no_requeue ->
        amqp_channel:call(Channel, #'basic.reject'{delivery_tag = DeliveryTag, requeue = false}),
        {noreply, State};
      ack ->
        amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DeliveryTag}),
        {noreply, State}
    end;
handle_info({'DOWN', _MRef, process, _Pid, Reason}, State) ->
    error_logger:info_msg("Closing down due to channel going down: ~p", [Reason]),
	{stop, Reason, State}.

%% @private
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

%% @private
handle_cast(_Message, State) ->
    {noreply, State}.

%% Closes the channel this gen_server instance started
%% @private
terminate(_Reason, #state { channel = undefined }) ->
    ok;
terminate(_Reason, #state{channel = Channel}) ->
    amqp_channel:close(Channel),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    State.
    
%%--------------------------------------------------------------------------

try_connect(ConnectionRef, Q, QArgs, Fun, ReconnectTime) ->
  case amqp_connection_mgr:fetch(ConnectionRef) of
    {ok, Connection} ->
       {ok, Channel} = amqp_connection:open_channel(
                          Connection, {amqp_direct_consumer, [self()]}),
       erlang:monitor(process, Channel),
       #'queue.declare_ok' { queue = Q } =
           amqp_channel:call(Channel, #'queue.declare'{queue = Q, arguments = QArgs }),
       #'basic.consume_ok'{} = amqp_channel:call(Channel, #'basic.consume'{queue = Q}),
       #state{channel = Channel, handler = Fun};
    {error, econnrefused} ->
      error_logger:error_report([no_connection]),
      timer:send_after(ReconnectTime, self(),
                       {reconnect, ConnectionRef, Q, QArgs, Fun, min(ReconnectTime * 2, ?MAX_RECONNECT)}),
      #state { channel = undefined, handler = Fun }
  end.
