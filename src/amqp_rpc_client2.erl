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

%% @doc This module allows the simple execution of an asynchronous RPC over
%% AMQP. It frees a client programmer of the necessary having to AMQP
%% plumbing. Note that the this module does not handle any data encoding,
%% so it is up to the caller to marshall and unmarshall message payloads
%% accordingly.
%%
%% NOTE: The way this AMQP Client is implemented, a caller will be blocked,
%% but the gen_server run by this process will not. Tests on the local machine
%% here easily obtains 8000+ reqs/s with this approach.
%% @end
-module(amqp_rpc_client2).

-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(gen_server).

-export([start_link/3]).
-export([cast/2, call/2, call/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-record(state, {channel,
                reply_queue,
                exchange,
                routing_key,
                continuations = dict:new(),
                correlation_id = 0}).

-define(MAX_RECONNECT, timer:seconds(30)).

%%--------------------------------------------------------------------------

%% @doc Starts a new RPC client instance that sends requests to a
%% specified queue. This function returns the pid of the RPC client process
%% that can be used to invoke RPCs and stop the client.
-spec start_link(Name, ConnRef, RoutingKey) -> {ok, pid()}
  when Name :: atom(),
       ConnRef :: pid(),
       RoutingKey :: binary().
start_link(Name, ConnRef, RoutingKey) ->
    gen_server:start_link({local, Name}, ?MODULE, [ConnRef, RoutingKey], []).

%% @doc Send a fire-and-forget message to the queue.
%% This implements the usual cast operation where a message is forwarded to a queue.
%% Note that there is *no* guarantee that the message will be sent. In particular,
%% if the queue is down, the message will be lost.
%% @end
-spec cast(RpcClient, Payload) -> ok
  when RpcClient :: atom() | pid(),
       Payload :: binary().
cast(RpcClient, Payload) ->
  gen_server:cast(RpcClient, {cast, Payload}).

%% @equiv call(RpcClient, Payload, 5000)
call(RpcClient, Payload) ->
    call(RpcClient, Payload, 5000).

%% @doc Invokes an RPC. Note the caller of this function is responsible for
%% encoding the request and decoding the response. If the timeout is hit, the
%% calling process will exit.
%% @end
-spec call(RpcClient, Request, Timeout) -> Response
  when RpcClient :: atom() | pid(),
       Request :: binary(),
       Timeout :: pos_integer(),
       Response :: {ok, binary()} | {error, term()}.
call(RpcClient, Payload, Timeout) ->
    gen_server:call(RpcClient, {call, Payload}, Timeout).

%%--------------------------------------------------------------------------

%% Sets up a reply queue for this client to listen on
setup_reply_queue(State = #state{channel = Channel}) ->
    #'queue.declare_ok'{queue = Q} =
        amqp_channel:call(Channel, #'queue.declare'{}),
    State#state{reply_queue = Q}.

%% Registers this RPC client instance as a consumer to handle rpc responses
setup_consumer(#state{channel = Channel, reply_queue = Q}) ->
    amqp_channel:call(Channel, #'basic.consume'{queue = Q}).

%% Publishes to the broker, stores the From address against
%% the correlation id and increments the correlationid for
%% the next request
publish(Payload, From,
        State = #state{channel = Channel,
                       reply_queue = Q,
                       exchange = X,
                       routing_key = RoutingKey,
                       correlation_id = CorrelationId,
                       continuations = Continuations}) ->
    Props = #'P_basic'{correlation_id = <<CorrelationId:64>>,
                       content_type = <<"application/octet-stream">>,
                       reply_to = Q},
    Publish = #'basic.publish'{exchange = X,
                               routing_key = RoutingKey,
                               mandatory = true},
    amqp_channel:call(Channel, Publish, #amqp_msg{props = Props,
                                                  payload = Payload}),
    State#state{correlation_id = CorrelationId + 1,
                continuations = dict:store(CorrelationId, From, Continuations)}.

%% Publish on a queue in a fire-n-forget fashion.
publish_cast(Payload,
             #state { channel = Channel,
                      exchange = X,
                      routing_key = RoutingKey }) ->
    Props = #'P_basic' { content_type = <<"application/octet-stream">> },
    Publish = #'basic.publish'{exchange = X,
                               routing_key = RoutingKey,
                               mandatory = true},
    amqp_channel:call(Channel, Publish, #amqp_msg { props = Props,
                                                    payload = Payload }).
                                                    
%%--------------------------------------------------------------------------

%% Sets up a reply queue and consumer within an existing channel
%% @private
init([ConnectionRef, RoutingKey]) ->
	{ok, try_connect(ConnectionRef, RoutingKey, 1000)}.
	

%% Closes the channel this gen_server instance started
%% @private
terminate(_Reason, #state{channel = Channel}) ->
    amqp_channel:close(Channel),
    ok.

%% Handle the application initiated stop by just stopping this gen server
%% @private
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

%% @private
handle_call({call, _Payload}, _From, #state { channel = undefined } = State) ->
    {reply, {error, no_connection}, State};
handle_call({call, Payload}, From, State) ->
    NewState = publish(Payload, From, State),
    {noreply, NewState}.

%% @private
handle_cast({cast, _Payload}, #state { channel = undefined } = State) ->
    %% We can't do anything but throw away the message here!
    {noreply, State};
handle_cast({cast, Payload}, State) ->
    publish_cast(Payload, State),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({reconnect, CRef, RoutingKey, ReconnectTime}, #state { channel = undefined }) ->
    {noreply, try_connect(CRef, RoutingKey, ReconnectTime)};
handle_info({'DOWN', _, process, Channel, Reason},
            #state { channel = Channel } = State) ->
    lager:warning("Channel ~p going down... stopping", [Channel]),
    {stop, {error, {channel_down, Reason}}, State};
handle_info({#'basic.consume'{}, _Pid}, State) ->
    {noreply, State};
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};
handle_info(#'basic.cancel'{}, State) ->
    {noreply, State};
handle_info(#'basic.cancel_ok'{}, State) ->
    {stop, normal, State};
handle_info({#'basic.deliver'{delivery_tag = DeliveryTag},
            #amqp_msg{props = #'P_basic'{correlation_id = <<Id:64>>},
                                         payload = Payload}},
                            State = #state{continuations = Conts, channel = Channel}) ->
    From = dict:fetch(Id, Conts),
    gen_server:reply(From, {ok, Payload}),
    amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DeliveryTag}),
    {noreply, State#state{continuations = dict:erase(Id, Conts) }}.

%% @private
code_change(_OldVsn, State, _Extra) ->
    State.

%%--------------------------------------------------------------------------
    
try_connect(ConnectionRef, RoutingKey, ReconnectTime) ->
	case amqp_connection_mgr:fetch(ConnectionRef) of
	    {ok, Connection} ->
	      {ok, Channel} = amqp_connection:open_channel(Connection, {amqp_direct_consumer, [self()]}),
          erlang:monitor(process, Channel),
          InitialState = #state{channel     = Channel,
                                exchange    = <<>>,
                                routing_key = RoutingKey},
          State = setup_reply_queue(InitialState),
          setup_consumer(State),
          State;
        {error, econnrefused} ->
          lager:warning("RPC Client has no working channel, waiting"),
          timer:send_after(ReconnectTime, self(), {reconnect, ConnectionRef, RoutingKey,
                                                              min(ReconnectTime * 2, ?MAX_RECONNECT)}),
          #state { channel = undefined }
      end.
