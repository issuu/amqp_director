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
-export([cast/4, cast/5, call/3, call/4, call/5]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2, format_status/2]).

-record(state, {channel,
                reply_queue,
                app_id,
                exchange,
                routing_key,
                ack = true, % Should we ack messages?
                continuations = dict:new(),
                monitors = dict:new(),
                correlation_id = 0}).

-define(MAX_RECONNECT, timer:seconds(30)).

%%--------------------------------------------------------------------------

%% @doc Starts a new RPC client instance that sends requests to a
%% specified queue. This function returns the pid of the RPC client process
%% that can be used to invoke RPCs and stop the client.
-spec start_link(Name, Configuration, ConnRef) -> {ok, pid()}
  when Name :: atom(),
       Configuration :: term(),
       ConnRef :: pid().
start_link(Name, Configuration, ConnRef) ->
    gen_server:start_link({local, Name}, ?MODULE, [Configuration, ConnRef], []).

%% @doc Send a fire-and-forget message to the exchange.
%% This implements the usual cast operation where a message is forwarded to a queue.
%% Note that there is *no* guarantee that the message will be sent. In particular,
%% if the queue is down, the message will be lost. You also have to supply a ContentType
%% as well as a message type for the system.
%% @end
-spec cast(RpcClient, Payload, ContentType, Type) -> ok
  when RpcClient :: atom() | pid(),
       Payload :: binary(),
       ContentType :: binary(),
       Type :: binary().
cast(RpcClient, Payload, ContentType, Type) ->
  gen_server:cast(RpcClient, {cast, Payload, ContentType, Type}).

%% @doc Send a fire-and-forget message to the exchange with a routing key
%% This call acts like the call cast/4 except that it also allows the user to
%% supply a routing key
-spec cast(RpcClient, Payload, ContentType, Type, RoutingKey) -> ok
  when RpcClient :: atom() | pid(),
       Payload :: binary(),
       ContentType :: binary(),
       Type :: binary(),
       RoutingKey :: binary().
cast(RpcClient, Payload, ContentType, Type, RoutingKey) ->
  gen_server:cast(RpcClient, {rk_cast, Payload, ContentType, Type, RoutingKey}).

%% @equiv call(RpcClient, Payload, ContentType, 5000)
call(RpcClient, Payload, ContentType) ->
    call(RpcClient, Payload, ContentType, 5000).



%% @end
%% @doc Invokes an RPC. Note the caller of this function is responsible for
%% encoding the request and decoding the response. If the timeout is hit, the
%% calling process will exit. The call will set `ContentType' as the type of
%% the message (essentially the mime type). The `Type' of the message will always
%% be set to `request'.
%% @end
-spec call(RpcClient, Request, ContentType, Timeout) -> Response
  when RpcClient :: atom() | pid(),
       Request :: binary(),
       ContentType :: binary(),
       Timeout :: pos_integer(),
       Response :: {ok, binary()} | {error, term()}.
call(RpcClient, Payload, ContentType, Timeout) ->
    gen_server:call(RpcClient, {call, Payload, ContentType}, Timeout).

%% @doc Invokes an RPC. And also use a routing key to route the message.
%% This variant is equivalent to @ref call/4 but it also allows the caller to
%% specify a routing key to use when publishing a message.
%% @end
-spec call(RpcClient, Request, ContentType, RoutingKey, Timeout) -> Response
  when RpcClient :: atom() | pid(),
       Request :: binary(),
       ContentType :: binary(),
       Timeout :: pos_integer(),
       RoutingKey :: binary(),
       Response :: {ok, binary()} | {error, term()}.
call(RpcClient, Payload, ContentType, RoutingKey, Timeout) ->
    gen_server:call(RpcClient, {rk_call, Payload, ContentType, RoutingKey}, Timeout).

%%--------------------------------------------------------------------------



%% Sets up a reply queue for this client to listen on
setup_queues(State = #state{channel = Channel}, Configuration) ->
    amqp_definitions:inject(Channel,
                             proplists:get_value(queue_definitions, Configuration, [])),

    %% Configuration of the Reply queue:
    RQ = #'queue.declare' { exclusive = true, auto_delete = true },
    case proplists:get_value(reply_queue, Configuration, undefined) of
      undefined ->
          % Set up an no-name reply queue
          #'queue.declare_ok'{queue = ReplyQ} = amqp_channel:call(Channel, RQ);
      none ->
          % No reply queue wanted, do not set up one. Calls won't work.
          ReplyQ = none;
      ReplyQ when is_binary(ReplyQ) ->
          Q = RQ#'queue.declare'{ queue = ReplyQ },
          #'queue.declare_ok' { queue = ReplyQ } = amqp_channel:call(Channel, Q)
    end,
    State#state{reply_queue = ReplyQ}.

%% Registers this RPC client instance as a consumer to handle rpc responses
setup_consumer(#state{channel = _Channel, reply_queue = none}) ->
    ok;
setup_consumer(#state{channel = Channel, reply_queue = Q, ack = Ack}) ->
    amqp_channel:register_return_handler(Channel, self()),
    amqp_channel:call(Channel, #'basic.qos'{prefetch_count = 100}),
    #'basic.consume_ok' {} = amqp_channel:call(Channel, #'basic.consume'{queue = Q, no_ack = not Ack}).

%% Publishes to the broker, stores the From address against
%% the correlation id and increments the correlationid for
%% the next request
publish(Payload, ContentType, {Pid, _Tag} = From, RoutingKey,
        State = #state{channel = Channel,
                       reply_queue = Q,
                       exchange = X,
                       correlation_id = CorrelationId,
                       app_id = AppId,
                       monitors = Monitors,
                       continuations = Continuations}) ->
    Props = #'P_basic'{correlation_id = list_to_binary(integer_to_list(CorrelationId)),
                       content_type = ContentType,
                       type = <<"request">>,
                       app_id = AppId,
                       reply_to = Q},
    %% Set Message options:
    %% Setting mandatory means that there must be a routable target queue
    %%  through the exchange. If no such queue exist, an error is returned out
    %%  of band and processed by the return handler.
    %% Setting immediate means that the routable target queue MUST
    %%  have a consumer on it currently. Otherwise routing a message to that
    %%  queue is also an error. For RPC we expect there to be a handler currently
    %%  connected. If not we rather handle the error quickly.
    Publish = #'basic.publish'{exchange = X,
                               routing_key = RoutingKey,
                               mandatory = true },
    ok = amqp_channel:call(Channel, Publish, #amqp_msg{props = Props, payload = Payload}),
    Ref = erlang:monitor(process, Pid),
    {ok,
      State#state{correlation_id = CorrelationId + 1,
                  continuations = dict:store(CorrelationId, {From, Ref}, Continuations),
                  monitors = dict:store(Ref, CorrelationId, Monitors)}}.

%% Publish on a queue in a fire-n-forget fashion.
publish_cast(Payload, ContentType, Type, RoutingKey,
             #state { channel = Channel,
                      exchange = X,
                      app_id = AppId }) ->
    Props = #'P_basic'{content_type = ContentType,
                       type = Type,
                       app_id = AppId},
    Publish = #'basic.publish'{exchange = X,
                               routing_key = RoutingKey,
                               mandatory = false},
    amqp_channel:call(Channel, Publish, #amqp_msg { props = Props,
                                                    payload = Payload }).
                                                    
%%--------------------------------------------------------------------------

%% Sets up a reply queue and consumer within an existing channel
%% @private
init([Configuration, ConnectionRef]) ->
    process_flag(trap_exit, true),
    ReconnectTime = 500,
    timer:send_after(ReconnectTime, self(), {reconnect, Configuration, ConnectionRef,
                                             min(ReconnectTime * 2, ?MAX_RECONNECT)}),
	{ok, #state { channel = undefined }}.
	

%% Closes the channel this gen_server instance started
%% @private
terminate(_Reason, #state { channel = undefined }) ->
	ok;
terminate(_Reason, #state{channel = Channel}) ->
    catch amqp_channel:close(Channel),
    ok.

%% Handle the application initiated stop by just stopping this gen server
%% @private
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Msg, _From, #state { channel = undefined } = State) ->
    {reply, {error, no_connection}, State};
handle_call(_Msg, _From, #state { reply_queue = none } = State) ->
    {reply, {error, no_call_configuration}, State};
handle_call({call, Payload, ContentType}, From, #state { routing_key = RK} = State) ->
    {ok, NewState} = publish(Payload, ContentType, From, RK, State),
    {noreply, NewState};
handle_call({rk_call, Payload, ContentType, RoutingKey}, From, State) ->
     {ok, NewState} = publish(Payload, ContentType, From, RoutingKey, State),
     {noreply, NewState}.


%% @private
handle_cast({cast, _Payload, _ContentType, _Type}, #state { channel = undefined } = State) ->
    %% We can't do anything but throw away the message here!
    error_logger:info_msg("Warning - throwing away message for an undefined channel."),
    {noreply, State};
handle_cast({cast, Payload, ContentType, Type}, #state { routing_key = RK } = State) ->
    publish_cast(Payload, ContentType, Type, RK, State),
    {noreply, State};
handle_cast({rk_cast, Payload, ContentType, Type, RoutingKey}, State) ->
    publish_cast(Payload, ContentType, Type, RoutingKey, State),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({reconnect, Configuration, CRef, ReconnectTime}, #state { channel = undefined }) ->
    {noreply, try_connect(Configuration, CRef, ReconnectTime)};
handle_info({'DOWN', _, process, Channel, Reason},
            #state { channel = Channel } = State) ->
    error_logger:info_msg("Channel ~p going down... stopping", [Channel]),
    {stop, {error, {channel_down, Reason}}, State#state{ channel = undefined }};
handle_info({'DOWN', MRef, process, _Pid, _Reason},
            #state { continuations = Continuations,
                     monitors = Monitors } = State) ->
    %% A client caller went down, usually due to a timeout
    case dict:find(MRef, Monitors) of
        error ->
            %% Stray Monitor. This can happen in a close-down-timeout-race
            {noreply, State};
        {ok, Id} ->
            %% Remove the Id as we can't use it anymore
            {noreply, State#state { continuations = dict:erase(Id, Continuations),
                                    monitors      = dict:erase(MRef, Monitors) }}
    end;
handle_info({#'basic.consume'{}, _Pid}, State) ->
    {noreply, State};
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};
handle_info(#'basic.cancel'{}, State) ->
    {stop, amqp_server_cancelled, State};
handle_info(#'basic.cancel_ok'{}, State) ->
    {stop, normal, State};
handle_info({#'basic.return' { reply_code = ReplyCode },
             #amqp_msg { props = #'P_basic' { correlation_id = Id }} },
            #state { continuations = Conts,
                     monitors = Monitors } = State) ->
    CorrelationId = list_to_integer(binary_to_list(Id)),
    case dict:find(CorrelationId, Conts) of
        error ->
            %% Stray message. If the client has timed out, this can happen
            {noreply, State};
        {ok, {From, MonitorRef}} ->
            erlang:demonitor(MonitorRef),
            gen_server:reply(From, handle_reply_code(ReplyCode)),
            {noreply, State#state { continuations = dict:erase(CorrelationId, Conts),
                                    monitors = dict:erase(MonitorRef, Monitors) }}
    end;
handle_info({#'basic.deliver'{delivery_tag = DeliveryTag},
            #amqp_msg{props = #'P_basic'{correlation_id = Id,
                                         content_type = ContentType},
                                         payload = Payload}},
           State = #state{ continuations = Conts,
                           monitors = Monitors,
                           channel = Channel,
                           ack = Ack }) ->
    %% Always Ack the response messages, before processing
    CorrelationId = list_to_integer(binary_to_list(Id)),
    case Ack of true -> amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DeliveryTag});
                false -> ok
    end,
    case dict:find(CorrelationId, Conts) of
        error ->
            %% Stray message. If the client has timed out, this can happen
            {noreply, State};
        {ok, {From, MonitorRef}} ->
             erlang:demonitor(MonitorRef),
             gen_server:reply(From, {ok, Payload, ContentType}),
             {noreply, State#state{ continuations = dict:erase(CorrelationId, Conts),
                                    monitors = dict:erase(MonitorRef, Monitors) }}
    end.
    
%% @private
code_change(_OldVsn, State, _Extra) ->
    State.

format_status(_, [_Pdict, #state { continuations = Conts,
                                   monitors = Monitors,
                                   correlation_id = Cid,
                                   channel = Channel,
                                   routing_key = RoutingKey }]) ->
    St = [{continuation_size, dict:size(Conts)},
          {monitor_size, dict:size(Monitors)},
          {correlation_id, Cid},
          {channel, Channel},
          {routing_key, RoutingKey}],
    {data, [{"State", St}]}.
     
%%--------------------------------------------------------------------------
    
handle_reply_code(313) -> {error, no_consumers};
handle_reply_code(N) when is_integer(N) -> {error, {reply_code, N}}.

try_connect(Configuration, ConnectionRef, ReconnectTime) ->
	case amqp_connection_mgr:fetch(ConnectionRef) of
	    {ok, Connection} ->
	      {ok, Channel} = amqp_connection:open_channel(Connection, {amqp_direct_consumer, [self()]}),
          erlang:monitor(process, Channel),
          InitialState = #state{channel     = Channel,
                                exchange    = proplists:get_value(exchange, Configuration, <<>>),
                                app_id      = proplists:get_value(app_id, Configuration,
                                                                  list_to_binary(atom_to_list(node()))),
                                routing_key = proplists:get_value(routing_key, Configuration),
                                ack = not (proplists:get_value(no_ack, Configuration, false)) },
          State = setup_queues(InitialState, Configuration),
          setup_consumer(State),
          State;
        {error, econnrefused} ->
          error_logger:info_msg("RPC Client has no working channel, waiting"),
          timer:send_after(ReconnectTime, self(), {reconnect, Configuration, ConnectionRef,
                                                              min(ReconnectTime * 2, ?MAX_RECONNECT)}),
          #state { channel = undefined }
      end.
