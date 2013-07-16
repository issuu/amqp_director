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
-module(ad_client).

-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(gen_server).

%% Lifetime API
-export([start_link/3, await/1, await/2]).

%% Operational API
-export([cast/6, cast/7, call/5, call/6]).

%% Callback API
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2, format_status/2]).

-record(state, {channel,
                reply_queue,
                app_id,
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
    gen_server:start_link({local, Name}, ?MODULE, [Name, Configuration, ConnRef], []).

%% @equiv await(Name, infinity)
-spec await(Name) -> term()
  when Name :: atom().
await(Name) -> gproc:await({n, l, Name}).

%% @doc Await the connection on a client.
%% Await that a client has a connection to the server. This can be
%% used in start-up sequences to ensure that you have a connection. It
%% can be used to await in complex start-up sequences so you can be
%% sure there is a connection. The timeout specifies for how long to wait.
%% @end
-spec await(Name, Timeout) -> Result
  when Name :: atom(),
       Timeout :: integer() | 'infinity',
       Result :: term().
await(Name, Timeout) -> gproc:await({n, l, Name}, Timeout).

%% @equiv cast(Client, Exch, Rk, Payload, Type, ContentType, [])
cast(RpcClient, Exchange, RoutingKey, Payload, Type, ContentType) ->
    cast(RpcClient, Exchange, RoutingKey, Payload, Type, ContentType, []).

%% @doc Send a fire-and-forget message to the exchange.
%% This implements the usual cast operation where a message is forwarded to a queue.
%% Note that there is *no* guarantee that the message will be sent. In particular,
%% if the queue is down, the message will be lost. You also have to supply a ContentType
%% as well as a message type for the system.
%% @end
-spec cast(RpcClient, Exchange, RoutingKey, Payload, ContentType, Type, Options) -> ok
  when RpcClient :: atom() | pid(),
       Exchange :: binary(),
       RoutingKey :: binary(),
       Payload :: binary(),
       ContentType :: binary(),
       Type :: binary(),
       Options :: [atom() | {atom(), term()}].
cast(RpcClient, Exchange, RoutingKey, Payload, ContentType, Type, Options) ->
    Durability = decode_durability(Options),
    gen_server:cast(RpcClient, {cast, Exchange, RoutingKey, Payload, ContentType, Type, Durability}).

%% @equiv call(RpcClient, Payload, ContentType, 5000)
call(RpcClient, Exchange, RoutingKey, Payload, ContentType) ->
    call(RpcClient, Exchange, RoutingKey, Payload, ContentType, [{timeout, 5000}]).

%% @doc Invokes an RPC.
%% Note the caller of this function is responsible for
%% encoding the request and decoding the response. If the timeout is hit, the
%% calling process will exit. The call will set `ContentType' as the type of
%% the message (essentially the mime type). The `Type' of the message will always
%% be set to `request'.
%% @end
-spec call(RpcClient, Exchange, RoutingKey, Request, ContentType, Options) ->
      {ok, Payload, ContentType} | {error, Reason}
  when RpcClient :: atom() | pid(),
       Exchange :: binary(),
       RoutingKey :: binary(),
       Request :: binary(),
       ContentType :: binary(),
       Options :: [{atom(), term()} | atom()],
       Payload :: binary(),
       ContentType :: binary(),
       Reason :: term().
call(RpcClient, Exchange, RoutingKey, Payload, ContentType, Options) ->
    Timeout = proplists:get_value(timeout, Options, infinity),
    Durability = decode_durability(Options),
    gen_server:call(RpcClient, {call, Exchange, RoutingKey, Payload, ContentType, Durability}, Timeout).

%%--------------------------------------------------------------------------

%% Sets up a reply queue and consumer within an existing channel
%% @private
init([Name, Configuration, ConnectionRef]) ->
    process_flag(trap_exit, true),
    case amqp_definitions:verify_config(Configuration) of
        ok ->
            ReconnectTime = 500,
            timer:send_after(ReconnectTime, self(),
                             {reconnect, Name, Configuration, ConnectionRef,
                              min(ReconnectTime * 2, ?MAX_RECONNECT)}),
            {ok, #state { channel = undefined }};
        {conflict, Msg, BadQueueDef} ->
            error_logger:error_msg("~p: ~p", [Msg, BadQueueDef]),
            {stop, Msg}
    end.

%% Closes the channel this gen_server instance started
%% @private
terminate(_Reason, #state { channel = undefined }) -> ok;
terminate(_Reason, #state{channel = Channel}) ->
    catch amqp_channel:close(Channel),
    ok.

%% Handle the application initiated stop by just stopping this gen server
%% @private
handle_call(_Msg, _From, #state { channel = undefined } = State) ->
    {reply, {error, no_connection}, State};
handle_call(_Msg, _From, #state { reply_queue = none } = State) ->
    {reply, {error, no_call_configuration}, State};
handle_call({call, Exchange, RoutingKey, Payload, ContentType, Durability}, From, #state {} = State) ->
    {ok, NewState} = publish(Payload, ContentType, From, Exchange, RoutingKey, Durability, State),
    {noreply, NewState}.

%% @private
handle_cast({cast, _Payload, _ContentType, _Type}, #state { channel = undefined } = State) ->
    %% We can't do anything but throw away the message here, as we
    %% don't know the caller
    error_logger:info_msg("Throwing away message for an undefined channel."),
    {noreply, State};
handle_cast({cast, Exchange, RoutingKey, Payload, ContentType, Type, Durability},
            #state {} = State) ->
    publish_cast(Payload, Exchange, RoutingKey, ContentType, Type, Durability, State),
    {noreply, State}.

%% @private
%% Reconnectinons
handle_info({reconnect, Name, Configuration, CRef, ReconnectTime},
            #state { channel = undefined }) ->
    {noreply, try_connect(Name, Configuration, CRef, ReconnectTime)};
%% Monitor 'DOWN' messages for dead clients or connections
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
%% Handling of AMQP level messages
handle_info({#'basic.consume'{}, _Pid}, State) -> {noreply, State};
handle_info(#'basic.consume_ok'{}, State) -> {noreply, State};
handle_info(#'basic.cancel'{}, State) -> {stop, amqp_server_cancelled, State};
handle_info(#'basic.cancel_ok'{}, State) -> {stop, normal, State};
handle_info({#'basic.return' { reply_code = ReplyCode },
             #amqp_msg { props = #'P_basic' { correlation_id = CorrelationIdBin }} },
            #state { continuations = Conts,
                     monitors = Monitors } = State) ->
    case dict:find(CorrelationIdBin, Conts) of
        error ->
            %% Stray message. If the client has timed out, this can happen
            {noreply, State};
        {ok, {From, MonitorRef}} ->
            erlang:demonitor(MonitorRef),
            gen_server:reply(From, handle_reply_code(ReplyCode)),
            {noreply, State#state { continuations = dict:erase(CorrelationIdBin, Conts),
                                    monitors = dict:erase(MonitorRef, Monitors) }}
    end;
handle_info({#'basic.deliver'{delivery_tag = DeliveryTag},
            #amqp_msg{props = #'P_basic'{correlation_id = CorrelationIdBin,
                                         content_type = ContentType},
                      payload = Payload}},
            State = #state{ continuations = Conts,
                            monitors = Monitors,
                            channel = Channel,
                            ack = ShouldAck }) ->
    %% Always Ack the response messages, before processing
    handle_ack(ShouldAck, Channel, DeliveryTag), 
    case dict:find(CorrelationIdBin, Conts) of
        error ->
            %% Stray message. If the client has timed out, this can happen
            {noreply, State};
        {ok, {From, MonitorRef}} ->
             erlang:demonitor(MonitorRef),
             gen_server:reply(From, {ok, Payload, ContentType}),
             {noreply, State#state{ continuations = dict:erase(CorrelationIdBin, Conts),
                                    monitors = dict:erase(MonitorRef, Monitors) }}
    end.

%% @private
code_change(_OldVsn, State, _Extra) ->
    State.

format_status(_, [_Pdict, #state { continuations = Conts,
                                   monitors = Monitors,
                                   correlation_id = Cid,
                                   channel = Channel
                                   }]) ->
    St = [{continuation_size, dict:size(Conts)},
          {monitor_size, dict:size(Monitors)},
          {correlation_id, Cid},
          {channel, Channel}],
    {data, [{"State", St}]}.

%% --------------------------------------------------

%% @doc Sets up the AMQP idempotent state
setup_amqp_state(State = #state{channel = Channel}, Configuration) ->
    amqp_definitions:inject(Channel,
                            proplists:get_value(queue_definitions, Configuration, [])),

    RQ = setup_reply_queue(
           Channel,
           proplists:get_value(reply_queue, Configuration, undefined)),
    State#state { reply_queue = RQ }.

setup_reply_queue(Channel, undefined) ->
    #'queue.declare_ok'{queue = ReplyQ} =
        amqp_channel:call(Channel,
                          #'queue.declare' { exclusive = true, auto_delete = true }),
    ReplyQ;
setup_reply_queue(_Channel, none) -> none;
setup_reply_queue(Channel, ReplyQ) when is_binary(ReplyQ) -> 
    #'queue.declare_ok' { queue = ReplyQ } =
        amqp_channel:call(Channel,
                          #'queue.declare' { exclusive = true,
                                             auto_delete = true,
                                             queue = ReplyQ}),
    ReplyQ.

%% Registers this RPC client instance as a consumer to handle rpc responses
setup_consumer(#state{channel = _Channel, reply_queue = none}) -> ok;
setup_consumer(#state{channel = Channel, reply_queue = Q, ack = Ack}) ->
    amqp_channel:register_return_handler(Channel, self()),
    amqp_channel:call(Channel, #'basic.qos'{prefetch_count = 100}),
    #'basic.consume_ok' {} =
        amqp_channel:call(Channel,
                          #'basic.consume'{queue = Q, no_ack = not Ack}).

%% Publishes to the broker, stores the From address against
%% the correlation id and increments the correlationid for
%% the next request
publish(Payload, ContentType, {Pid, _Tag} = From, Exchange, RoutingKey,
        Durability,
        State = #state{channel = Channel,
                       reply_queue = Q,
                       correlation_id = CorrelationId,
                       app_id = AppId,
                       monitors = Monitors,
                       continuations = Continuations}) ->
    CorrelationIdBin = list_to_binary(integer_to_list(CorrelationId)),
    Props = #'P_basic'{correlation_id = CorrelationIdBin,
                       content_type = ContentType,
                       type = <<"request">>,
                       app_id = AppId,
                       reply_to = Q,
                       delivery_mode = case Durability of
                                           transient -> 1;
                                           persistent -> 2
                                       end},
    %% Set Message options:
    %% Setting mandatory means that there must be a routable target queue
    %%  through the exchange. If no such queue exist, an error is returned out
    %%  of band and processed by the return handler.
    Publish = #'basic.publish'{exchange = Exchange,
                               routing_key = RoutingKey,
                               mandatory = true },
    ok = amqp_channel:cast(Channel, Publish, #amqp_msg{ props = Props,
                                                        payload = Payload }),
    Ref = erlang:monitor(process, Pid),
    {ok,
      State#state{correlation_id = CorrelationId + 1,
                  continuations = dict:store(CorrelationIdBin, {From, Ref}, Continuations),
                  monitors = dict:store(Ref, CorrelationIdBin, Monitors)}}.

%% Publish on a queue in a fire-n-forget fashion.
publish_cast(Payload, Exchange, RoutingKey, ContentType, Type,
             Durability,
             #state { channel = Channel,
                      app_id = AppId }) ->
    Props = #'P_basic'{content_type = ContentType,
                       type = Type,
                       app_id = AppId,
                       delivery_mode = case Durability of
                                           transient -> 1;
                                           persistent -> 2
                                       end},
    Publish = #'basic.publish'{exchange = Exchange,
                               routing_key = RoutingKey,
                               mandatory = false},
    amqp_channel:cast(Channel, Publish, #amqp_msg { props = Props,
                                                    payload = Payload }).

handle_reply_code(313) -> {error, no_consumers};
handle_reply_code(N) when is_integer(N) -> {error, {reply_code, N}}.

try_connect(Name, Configuration, ConnectionRef, ReconnectTime) ->
    case amqp_connection_mgr:fetch(ConnectionRef) of
        {ok, Connection} ->
            {ok, Channel} =
                amqp_connection:open_channel(Connection,
                                             {amqp_direct_consumer, [self()]}),
            %% Monitor the Channel for errors
            erlang:monitor(process, Channel),
            InitialState =
                #state{channel     = Channel,
                       app_id      = proplists:get_value(app_id, Configuration,
                                                         list_to_binary(atom_to_list(node()))),
                       ack = not (proplists:get_value(no_ack, Configuration, false))},
            State = setup_amqp_state(InitialState, Configuration),
            setup_consumer(State),
            gproc:add_local_name(Name),
            State;
        {error, econnrefused} ->
            error_logger:info_msg("RPC Client has no working channel, waiting"),
            timer:send_after(ReconnectTime,
                             self(),
                             {reconnect, Name, Configuration, ConnectionRef,
                                         min(ReconnectTime * 2, ?MAX_RECONNECT)}),
            #state { channel = undefined }
    end.

handle_ack(true, Channel, DeliveryTag) ->
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = DeliveryTag});
handle_ack(false, _Channel, _DeliveryTag) -> ok.

decode_durability(Options) ->
    case proplists:get_value(persistent, Options, false) of
        true -> persistent;
        false -> transient
    end.

             
