-module (amqp_director_connection).
-behaviour (gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-define (MAX_ATTEMPTS, 10).
-define (SLEEP, 5000).

-export ([start_link/2, register/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record (connecting_state, {attempts = ?MAX_ATTEMPTS, queue = [], conn_info}).
-record (state, {connection, registered = gb_trees:empty()}).

%%%
%%% API
%%%
start_link( Name, #amqp_params_network{} = AmqpConnectionInfo ) ->
    gen_server:start_link({local, Name}, ?MODULE, AmqpConnectionInfo, []).

register( ConnRef, CharacterPid ) ->
    gen_server:call( ConnRef, {register, CharacterPid} ).

%%%
%%% Callbacks
%%%
init( AmqpConnectionInfo ) ->
    { ok, #connecting_state{ conn_info = AmqpConnectionInfo }, 0 }.

% We are connected, register the character
handle_call( {register, Pid}, _From, #state{} = State ) ->
    {reply, ok, do_register(State, Pid)};

% We are still in a connecting state, queue the character
handle_call( {register, Pid}, _From, #connecting_state{ queue = Q } = State ) ->
    {reply, queued, State#connecting_state{ queue = [Pid | Q] }, 0};

handle_call( _Req, _From, State ) ->
    {reply, ok, State}.

handle_cast( _Msg, State ) ->
    {noreply, State}.

handle_info( timeout, #connecting_state{ attempts = 0} = State ) ->
    {stop, amqp_server_not_responding, State};
handle_info( timeout, #connecting_state{ attempts = Attempts, conn_info = ConnInfo, queue = Q} = State ) ->
    case amqp_connection:start(ConnInfo) of
        {error, econnrefused} ->
            {noreply, State#connecting_state{ attempts = Attempts - 1 }, ?SLEEP};
        {ok, Connection} ->
            erlang:monitor(process, Connection),
            S0 = #state{ connection = Connection },
            {noreply, flush_queue(S0, Q)}
    end;

% A monitored process terminated normally
handle_info( {'DOWN', _, process, _Pid, normal}, State ) ->
    {noreply, State};

% Connection process died, we die too
handle_info( {'DOWN', _, process, Conn, _}, #state{ connection = Conn } = State ) ->
    {stop, amqp_connection_down, State};
% A character process died, de-register from the local state.
% amqp_director_character_sup should restart it, so do not bother
handle_info( {'DOWN', _, process, Char, _}, #state{} = State) ->
    State0 = do_unregister(State, Char),
    {noreply, State0}.

terminate( _Reson, #connecting_state{} ) ->
    ok;
terminate( _Reason, #state{ connection = Conn } ) ->
    amqp_connection:close(Conn),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%
%%% Internals
%%%
do_unregister(#state{ registered = R } = State, Pid) ->
    Chan = gb_trees:get(Pid, R),
    amqp_channel:close(Chan),
    State#state{ registered = gb_trees:delete(Pid, R)  }.

do_register(#state{ connection = Conn, registered = R } = State, Pid) ->
    erlang:monitor(process, Pid),
    {ok, Channel} = amqp_connection:open_channel(Conn),
    R0 = gb_trees:insert(Pid, Channel, R), 
    amqp_director_character:init_amqp(Pid, Channel),
    State#state{ registered = R0 }.
    
flush_queue(State, []) -> State;
flush_queue(State, [Mod | Tail]) ->
    flush_queue(do_register(State, Mod), Tail).




