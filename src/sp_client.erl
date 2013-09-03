%% @doc This module implements Synchronous Pull (i.e. #'basic get') over AMQP.
%% It handles the reconnection and restart of failed child processes
%%
-module(sp_client).

-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(gen_server).

% External API
-export([pull/2]).

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

-spec pull(atom(), binary()) -> {ok, binary()} | empty.
pull(PullClient, Queue) ->
    gen_server:call(PullClient, {pull, Queue}).
    
-spec start_link(atom(), term(), pid()) -> {ok, pid()}.
start_link(Name, Configuration, ConnRef) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, Configuration, ConnRef], []).
         
init([_Name, Configuration, ConnectionRef]) ->
    timer:send_after(?RECONNECT_TIME, self(), {reconnect, Configuration, ConnectionRef}),
    {ok, #state{channel = undefined}}.

handle_call({pull, Queue}, _From, State) ->
    Get = #'basic.get'{queue = Queue, no_ack = true},
    Reply = case amqp_channel:call(State#state.channel, Get) of
        {#'basic.get_ok'{}, Payload} -> {ok, Payload};
        #'basic.get_empty'{} -> empty
    end,
    {reply, Reply, State}.

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
        {error, econnrefused} ->
            error_logger:info_msg("RPC Client has no working channel, waiting"),
            timer:send_after(?RECONNECT_TIME, self(), {reconnect, Configuration, ConnectionRef}),
            #state{channel = undefined}
    end.