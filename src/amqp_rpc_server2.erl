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
%% @hidden
-module(amqp_rpc_server2).
-behaviour(gen_server).

-compile([{parse_transform, lager_transform}]).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export([start_link/3]).

-record(state, {channel, handler,
                pre_ack = false, % should we ack messages before the handler is called?
                post_ack = true, % should we ack messages after the handler returns?
                delivery_mode = 1 % should reply msg persist (2) or not (1)?
}).
-define(MAX_RECONNECT, timer:seconds(30)).
-type rpc_handler_return() :: {reply, binary()} | ack | reject | reject_no_requeue.
-type rpc_handler() ::
fun(({#'basic.deliver'{}, #amqp_msg{}}) -> rpc_handler_return()) |
fun((binary(), binary(), binary()) -> rpc_handler_return()).
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
-spec start_link(ConnectionRef :: pid(), Config :: list({atom(), term()}), RpcHandler :: rpc_handler()) -> {ok, pid()}.
start_link(ConnectionRef, Config, Fun) ->
  HandlerFun = case erlang:fun_info(Fun, arity) of
                 {arity, 1} -> Fun;
                 {arity, 3} ->
                   %% wrap
                   fun({#'basic.deliver'{},
                        #amqp_msg{props   = #'P_basic'{content_type = ContentType,
                                                       type         = Type},
                                  payload = Payload}}) ->
                     Fun(Payload, ContentType, Type)
                   end
               end,
  gen_server:start_link(?MODULE, [ConnectionRef, Config, HandlerFun], []).

%%--------------------------------------------------------------------------

%% @private
init([ConnectionRef, Config, Fun]) ->
  process_flag(trap_exit, true),
  case amqp_definitions:verify_config(Config) of
    ok ->
      ReconnectTime = 500,
      timer:send_after(ReconnectTime, self(),
                       {reconnect, ConnectionRef, Config, Fun,
                        min(ReconnectTime * 2, ?MAX_RECONNECT)}),
      {ok, #state{channel = undefined, handler = Fun}};
    {conflict, Msg, Detail} ->
      lager:alert("Bad config [.. ~p: ~p ..]", [Msg, Detail]),
      {stop, Msg}
  end.

%% @private
handle_info(shutdown, State) ->
  {stop, normal, State};

%% @private
handle_info({reconnect, CRef, Config, Fun, ReconnectTime}, #state{channel = undefined}) ->
  {noreply, try_connect(CRef, Config, Fun, ReconnectTime)};
handle_info({#'basic.consume'{}, _}, State) ->
  {noreply, State};
handle_info(#'basic.consume_ok'{}, State) ->
  {noreply, State};
handle_info(#'basic.cancel'{}, State) ->
  {step, amqp_server_cancelled, State};
handle_info(#'basic.cancel_ok'{}, State) ->
  {stop, normal, State};
handle_info({#'basic.deliver'{delivery_tag = DeliveryTag},
             #amqp_msg{props = Props}} = InfoMsg,
            State = #state{handler = Fun, channel = Channel, post_ack = Ack, pre_ack = PreAck, delivery_mode = DeliveryMode}) ->
  #'P_basic'{correlation_id = CorrelationId,
             reply_to       = Q} = Props,
  case PreAck of
    true -> amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DeliveryTag});
    false -> ok
  end,
  case Fun(InfoMsg) of
    {reply, Response, CT} ->
      case Q of
        undefined -> ok;
        _ ->
          Properties = #'P_basic'{correlation_id = CorrelationId,
                                  content_type   = CT,
                                  type           = <<"reply">>,
                                  delivery_mode  = DeliveryMode},
          Publish = #'basic.publish'{exchange    = <<>>,
                                     routing_key = Q,
                                     mandatory   = true},
          amqp_channel:call(Channel, Publish, #amqp_msg{props   = Properties,
                                                        payload = Response})
      end,
      case Ack of true -> amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DeliveryTag});
        false -> ok
      end,
      {noreply, State};
    reject when Ack ->
      amqp_channel:call(Channel, #'basic.reject'{delivery_tag = DeliveryTag, requeue = true}),
      {noreply, State};
    reject when not Ack ->
      lager:notice("reject wanted, but channel set to no-ack"),
      {noreply, State};
    reject_no_requeue when Ack ->
      amqp_channel:call(Channel, #'basic.reject'{delivery_tag = DeliveryTag, requeue = false}),
      {noreply, State};
    reject_no_requeue when not Ack ->
      lager:notice("reject_no_requeue wanted, but channel set to no-ack"),
      {noreply, State};
    {reject_dump_msg, Msg} when Ack ->
      amqp_channel:call(Channel, #'basic.reject'{delivery_tag = DeliveryTag, requeue = false}),
      lager:error("Error AMQP message rejected due to ~p: ~p", [Msg, format_delivery(InfoMsg)]),
      {noreply, State};
    {reject_dump_msg, Msg} when not Ack ->
      lager:error("Error AMQP message rejected due to ~p: ~p", [Msg, format_delivery(InfoMsg)]),
      {noreply, State};
    ack when Ack ->
      amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DeliveryTag}),
      {noreply, State};
    ack when not Ack ->
      {noreply, State} % Ignore acks here
  end;
handle_info({#'basic.return'{} = ReturnMsg, _Msg}, State) ->
  lager:notice("Returned message from RPC server-handler reply: ~p", [ReturnMsg]),
  {noreply, State};
handle_info({'DOWN', _MRef, process, _Pid, Reason}, State) ->
  {stop, Reason, State#state{channel = undefined}};
handle_info({'EXIT', _Pid, normal}, State) ->
  %% Since we trap exits, normally exiting processes will yell in the log, quell them.
  {noreply, State};
handle_info({'EXIT', _Pid, shutdown}, State) ->
  %% Shutdowns are also normal exit reasons, quell them.
  {noreply, State};
handle_info({'EXIT', _Pid, Error}, State) ->
  {stop, {linked_process_exit, Error}, State};
handle_info(_Unknown, State) ->
  {noreply, State}.

%% @private
handle_call(stop, _From, State) ->
  {stop, normal, ok, State}.

%% @private
handle_cast(_Message, State) ->
  {noreply, State}.

%% Closes the channel this gen_server instance started
%% @private
terminate(_Reason, #state{channel = undefined}) ->
  ok;
terminate(_Reason, #state{channel = Channel}) ->
  catch amqp_channel:close(Channel),
  ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
  State.

%%--------------------------------------------------------------------------

try_connect(ConnectionRef, Config, Fun, ReconnectTime) ->
  try
    connect(ConnectionRef, Config, Fun)
  catch
    throw:reconnect ->
      %% No need to log here. Connection management handles this
      timer:send_after(ReconnectTime, self(),
                       {reconnect, ConnectionRef, Config, Fun, min(ReconnectTime * 2, ?MAX_RECONNECT)}),
      #state{channel = undefined, handler = Fun}
  end.

qos_configuration(Config) ->
  case proplists:get_value(qos, Config) of
    undefined -> #'basic.qos'{prefetch_count = 2};
    Qos when is_integer(Qos) -> #'basic.qos'{prefetch_count = Qos};
    Qos -> Qos
  end.

connect(ConnectionRef, Config, Fun) ->
  case amqp_connection_mgr:fetch(ConnectionRef) of
    {error, econnrefused} -> throw(reconnect);
    {ok, Connection} ->
      case amqp_connection:open_channel(
        Connection, {amqp_direct_consumer, [self()]}) of
        {ok, Channel} ->
          erlang:monitor(process, Channel),
          ok = amqp_definitions:inject(Channel, proplists:get_value(queue_definitions, Config, [])),
          case proplists:get_value(consume_queue, Config, undefined) of
            undefined -> exit(no_queue_to_consume);
            Q ->
              ConsumerTag = proplists:get_value(consumer_tag, Config, <<"">>),
              NoAck = proplists:get_value(no_ack, Config, false),
              PreAck = proplists:get_value(pre_ack, Config, false),
              PostAck = case PreAck of
                          true -> false;
                          _ -> not NoAck
                        end,
              DeliveryMode = case proplists:is_defined(reply_persistent, Config) of
                               false -> 1;
                               true -> 2
                             end,
              amqp_channel:register_return_handler(Channel, self()),
              amqp_channel:call(Channel, qos_configuration(Config)),
              #'basic.consume_ok'{} = amqp_channel:call(Channel, #'basic.consume'{
                queue = Q, consumer_tag = ConsumerTag, no_ack = NoAck}),
              #state{channel       = Channel,
                     handler       = Fun,
                     pre_ack       = PreAck,
                     post_ack      = PostAck,
                     delivery_mode = DeliveryMode}
          end;
        closing ->
          throw(reconnect)
      end
  end.

format_delivery({BasicDeliver, #amqp_msg{payload = Payload} = AmqpMsg}) ->
  Sz = byte_size(Payload),
  PayloadSz = iolist_to_binary([<<"Payload of ">>, integer_to_binary(Sz), <<" bytes">>]),
  {BasicDeliver, AmqpMsg#amqp_msg{payload = PayloadSz}}.
