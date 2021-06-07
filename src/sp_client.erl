%% @doc This module implements Synchronous Pull (i.e. #'basic get') over AMQP.
%% It handles the reconnection and restart of failed child processes
%%
-module(sp_client).

-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(gen_server).

% External API
-export([pull/2,
         get_queue_attributes/2,
         purge/2]).

%% Lifetime API
-export([start_link/3]).

% Callback API
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         format_status/2]).

-record(state, {channel = undefined,
                app_id = undefined}).

-define(RECONNECT_TIME, 5000).

-spec pull(atom() | pid(), binary()) -> {ok, binary()} | empty.
pull(PullClient, Queue) ->
    gen_server:call(PullClient, {pull, Queue}).

-spec get_queue_attributes(atom(), binary()) -> {ok, integer(), integer()}.
get_queue_attributes(PullClient, Queue) ->
    gen_server:call(PullClient, {get_queue_attributes, Queue}).

-spec purge(atom(), binary()) -> {ok, integer()}.
purge(PullClient, Queue) ->
    gen_server:call(PullClient, {purge, Queue}).

-spec start_link(atom(), term(), pid()) -> {ok, pid()}.
start_link(Name, Configuration, ConnRef) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, Configuration, ConnRef], []).

init([_Name, Configuration, ConnectionRef]) ->
    timer:send_after(?RECONNECT_TIME, self(), {reconnect, Configuration, ConnectionRef}),
    {ok, #state{channel = undefined}}.

handle_call({pull, Queue}, _From, State) ->
    Get = #'basic.get'{queue = Queue, no_ack = true},
    Reply = case amqp_channel:call(State#state.channel, Get) of
        {#'basic.get_ok'{}, #amqp_msg{payload = Payload}} -> {ok, Payload};
        #'basic.get_empty'{} -> empty
    end,
    {reply, Reply, State};
handle_call({get_queue_attributes, Queue}, _From, State) ->
    Declare = #'queue.declare'{queue = Queue, passive = true},
    #'queue.declare_ok'{message_count = MCount, consumer_count = CCount} = amqp_channel:call(State#state.channel, Declare),
    {reply, {ok, MCount, CCount}, State};
handle_call({purge, Queue}, _From, State) ->
    Purge = #'queue.purge'{queue = Queue},
    #'queue.purge_ok'{message_count = Count} = amqp_channel:call(State#state.channel, Purge),
    {reply, {ok, Count}, State}.

handle_cast(_Request, State) -> {noreply, State}. % Not used

handle_info({reconnect, Configuration, ConnectionRef},
            #state{channel = undefined}) ->
    {noreply, try_connect(Configuration, ConnectionRef)}.

terminate(_Reason, #state{channel = undefined}) -> ok;
terminate(_Reason, #state{channel = Channel}) ->
    catch(amqp_channel:close(Channel)),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}. % Code swapping not used

format_status(_Opt, [_PDict, State]) -> {?MODULE, State}. % For debugging

% Internal
try_connect(Configuration, ConnectionRef) ->
    case amqp_connection_mgr:fetch(ConnectionRef) of
        {ok, Connection} ->
            {ok, Channel} = amqp_connection:open_channel(Connection, {amqp_direct_consumer, [self()]}),
            amqp_definitions:inject(Channel, proplists:get_value(queue_definitions, Configuration, [])),
            AppId = proplists:get_value(app_id, Configuration, list_to_binary(atom_to_list(node()))),
            #state{channel = Channel, app_id  = AppId};
        {error, enotstarted} ->
            timer:send_after(?RECONNECT_TIME, self(), {reconnect, Configuration, ConnectionRef}),
            #state{channel = undefined};
        {error, econnrefused} ->
            timer:send_after(?RECONNECT_TIME, self(), {reconnect, Configuration, ConnectionRef}),
            #state{channel = undefined}
    end.
