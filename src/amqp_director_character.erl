-module (amqp_director_character).
-behaviour (gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-export ([start_link/2]).
-export ([name/1, init_amqp/2, publish/2]).
-export ([behaviour_info/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record (state, {name, module, channel, mod_state = undefined, pending = gb_trees:empty()}).
-record (connecting_state, {register = true, name, module, mod_args = undefined, conn_name}).

%%%
%%% API
%%%
behaviour_info(callbacks) ->
    [
    % name() -> atom() -- returns the name of the character.
    % Used for amqp_director_character:publish/2
    % It's always good to have an indirection layer.
    % {name,0},
    % init( term(), AmqpChannel ) -> {ok, State}
    % the first argument is the optional parameter passed to the character
    % calling e.g. amqp_director:add_character( {init_args, mymodule, [0,1]} , my_connection),
    % the callback will be called with mymodule:init( AmqpChannel, [0,1] )
    {init,2},
    % terminate( Reason, State ) -> Ignored
    {terminate,2},
    % handle( Message, State, Channel, CharacterRef ) -> {ok, NewState} | ok
    % Keep in mind that handle/3 is called in a worker process,
    % and the state is updated asynchronously
    %  -- to put in another way, perhaps it'll be better
    %     just to disallow character state changes
    {handle,4},
    % handle_failure( Message, State, Channel, CharacterRef ) -> Ignored
    % provides a way to nack a message
    {handle_failure,4},
    % handle a message before it is published
    % publish_hook( pre, { #'basic.publish'{}, term() } ) -> { #'basic.publish'{}, binary() }
    % Use cases:
    % - message marshalling
    % - message validation
    {publish_hook,2},
    % handle a message before/after it is delivered
    % deliver_hook( pre, { #'basic.deliver'{}, term() }, term(), pid() ) -> { #'basic.deliver'{}, binary() }
    % deliver_hook( post, { #'basic.deliver'{}, term() }, term(), pid() ) -> Ignored
    % Use cases:
    % - message marshalling (pre)
    % - auto ack/nack (ack in post, nack in handle_failure)
    {deliver_hook,3}
    ];
behaviour_info(_Other) ->
    undefined.

start_link( {CharacterName, _CharacterModule, _ModuleArgs} = CharInfo, ConnectionName ) ->
    gen_server:start_link({local, CharacterName}, ?MODULE, {CharInfo, ConnectionName}, []).
% start_link( CharacterModule, ConnectionName ) ->
%     gen_server:start_link({local, CharacterModule:name()}, ?MODULE, {{CharacterModule, undefined}, ConnectionName}, []).

init_amqp( Ref, AmqpChannel ) ->
    gen_server:call(Ref, {init_amqp, AmqpChannel}).

name( Ref ) ->
    gen_server:call(Ref, name).

-spec publish( term(), {#'basic.publish'{}, #amqp_msg{}} ) -> ok | {error, connecting}.
publish( ModName, AmqpPublishMessage ) ->
    gen_server:call(ModName, {publish, AmqpPublishMessage}). %Mod:publish_hook(pre, AmqpPublishMessage)}).

%%%
%%% Callbacks
%%%
init( {{Name, Mod, Args}, ConnName} ) ->
    {ok, #connecting_state{ name = Name, module = Mod, mod_args = Args, conn_name = ConnName }, 0}.
    % {ok, {register_connection, Mod,ConnName}, 0}.

handle_call( {init_amqp, Channel}, _From, #connecting_state{ name = Name, module = Mod, mod_args = Args } ) ->
    erlang:monitor(process, Channel),
    {ok, ModState} = Mod:init(Channel, Args),
    {reply, ok, #state{ name = Name, module = Mod, channel = Channel, mod_state = ModState }};

handle_call( name, _From, #state{ name = Name } = State ) ->
    {reply, Name, State};

% The client is responsible for retries, therefore if we are not yet connected,
% return {error, connecting}
% handle_call( {publish, _Msg}, _From, {register_connection, Mod, ConnName} ) ->
%     amqp_director_connection_sup:register_character(ConnName, self()),
%     {reply, {error, connecting}, #connecting_state{ module = Mod, conn_name = ConnName }};
handle_call( _Msg, _From, #connecting_state{ register = true } = State ) ->
    {reply, {error, connecting}, State, 0};
handle_call( _Msg, _From, #connecting_state{} = State) ->
    {reply, {error, connecting}, State};
% handle_call( {publish, _Msg}, _From, #connecting_state{ register = R, conn_name = ConnName } = State ) ->
%     S0 = case R of
%         true ->
%             amqp_director_connection_sup:register_character(ConnName, self()),
%             State#connecting_state{ register = false };
%         false -> State
%     end,
%     {reply, {error, connecting}, S0};
handle_call( {publish, AmqpPublishMessage}, _From, #state{ module = Mod, channel = Channel } = State ) ->
    {AmqpBasic, AmqpMessage} = Mod:publish_hook( pre, AmqpPublishMessage ),
    amqp_channel:cast(Channel, AmqpBasic, AmqpMessage),
    {reply, ok, State}.

handle_cast( {new_inner_state, NewInner, Pid}, State ) ->
    State0 = remove_pending_discard(State, Pid),
    {noreply, State0#state{ mod_state = NewInner }};
handle_cast( {remove_pending, Pid}, State ) ->
    {noreply, remove_pending_discard(State, Pid)};
handle_cast( _Request, State ) ->
    {noreply, State}.

handle_info( timeout, #connecting_state{ register = false } = State) ->
    {noreply, State};
handle_info( timeout, #connecting_state{ register = true, conn_name = ConnName } = State ) ->
    Ref = self(),
    spawn(fun() ->
        % We need to call this function *outside* the gen_server,
        % because this calls init_amqp, which calls the gen_server,
        % which of course causes a deadlock.
        % Other possible fix? perhaps make amqp_init a cast.
        amqp_director_connection_sup:register_character(ConnName, Ref)
    end),
    {noreply, State#connecting_state{ register = false }};

handle_info({do_terminate, Reason, State}, _) ->
    {stop, Reason, State};

% Channel process terminated, we need to terminate too.
handle_info({'DOWN', _, process, Chan, _}, #state{ channel = Chan } = State) ->
    % send a do_terminate message after 8s:
    % this should give the amqp_director_connection some time to reconnect.
    % Notice the 8s is a completely arbitrary number (except that an amqp connection
    % is expected to be re-established after 5s)
    erlang:send_after(8000, self(), {do_terminate, amqp_channel_process_down, State}),

    % notify clients that we are in a connecting_state,
    % therefore we cannot serve their requests
    {no_reply, #connecting_state{}};

% Just a worker process exiting normally
handle_info({'DOWN', _, process, _Pid, normal}, State) ->
    {noreply, State};

% A worker process exited abnormally
handle_info({'DOWN', _, process, Pid, _Reason}, #state{ module = Mod, channel = Chan, mod_state = ModState } = State) ->
    {State0, {Failure, _}} = remove_pending(State, Pid),
    Mod:handle_failure(Failure, ModState, Chan, self()),
    {noreply, State0};

% ..not entirely sure it should be here..
% perhaps a Mod:handle_info callback is more indicated
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info({#'basic.deliver'{}, _Contents} = AmqpMessage, #state{ module = Mod, channel = Chan, mod_state = InnerState} = State) ->
    % We received a message from the channel:
    %  - spawn_monitor a worker process that handle the message
    %  - if the worker terminates normally, well nothing bad happens
    %  - if the worker terminater abnormally, the character needs to handle the failure (handle_failure callback)
    Ref = self(),
    {Pid, Monitor} = spawn_monitor( fun() ->
        ToDeliver = Mod:deliver_hook( pre, AmqpMessage, Chan ),
        case Mod:handle( ToDeliver, InnerState, Chan, Ref ) of
            {ok, NewInnerState} ->
                gen_server:cast(Ref, {new_inner_state, NewInnerState, self()});
            ok ->
                gen_server:cast(Ref, {remove_pending, self()})% could actually just ignore everything else..
        end,
        Mod:deliver_hook( post, AmqpMessage, Chan )
    end ),

    State0 = add_pending(State, Pid, {AmqpMessage, Monitor}),
    { noreply, State0 }.

terminate( Reason, #state{ module = Mod } = State ) ->
    Mod:terminate( Reason, State ),
    ok;
terminate( Reason, #connecting_state{ module = Mod } = State ) ->
    Mod:terminate( Reason, State ),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%
%%% Internals
%%%
add_pending( #state{ pending = P } = State, Pid, Value ) ->
    State#state{ pending = gb_trees:insert(Pid, Value, P)  }.

remove_pending( #state{ pending = P } = State, Pid ) ->
    Value = gb_trees:get(Pid, P),
    {State#state{ pending = gb_trees:delete(Pid, P) }, Value}.

remove_pending_discard( #state{ pending = P } = State, Pid ) ->
    {_, Monitor} = gb_trees:get(Pid, P),
    erlang:demonitor(Monitor), 
    State#state{ pending = gb_trees:delete(Pid, P)  }.


