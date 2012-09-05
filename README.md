# AMQP Director: easily integrate AMQP into your Erlang apps

The aim of this library is to make it easy to integrate AMQP in Erlang applications.
It builds on top of amqp_client (https://github.com/jbrisbin/amqp_client).

## Goals

Supports multiple connections: Amqp characters can share a single amqp_connection, or start a new one.
In all cases, each character is provided with its own `amqp_channel`.

Reconnect: if a connection fails, it will try its best to reconnect to the server
(with some notion of "best").

Each character must provide an initialization function that accepts the `amqp_channel`.
If the character needs to subscribe to some queue, it needs to provide a callback function
for that purpose.

A bit of semantics:
 - should an `amqp_connection` fail, all linked characters are killed too
 - should a character fail, the `amqp_connection` it refers to is signaled,
   the character is removed from the list of linked characters
   and its channel is removed.

 - when publishing an AMQP message through an `amqp_director_character`,
   the result is either `ok` or `{error, Reason}`: it is responsibility
   of the caller to queue undelivered messages.

## Usage

Refer to the `example` directory for sample code.

### Publishing Amqp messages through `amqp_director_character`

To publish a message, use the function

    amqp_director_character:publish( character_ref(), {#'basic.publish'{}, #amqp_msg{}} ) -> ok | {error, Reason}

The message will be published using the channel of the referenced character. A character reference can either be the name or the gen_serve PID.
If something goes wrong (e.g. the connection has not been established yet), the function will return `{error, Reason}`.
It is responsibility of the caller to react accordingly.

### `amqp_director_character` callbacks

`amqp_director_character` defines a behaviour, and its callbacks must be implemented:

 - `init( Amqp_channel, term() ) -> {ok, term()}`: initialize the character. Returns the character state.
 - `terminate( Reason, State ) -> Ignored`: gives the character a chance to clean up resources when terminating.
 - `handle( { #'basic.deliver'{}, #amqp_msg{} }, State, Amqp_channel, CharPid ) -> {ok, NewState} | ok`: handle the
   reception of a message. Can optionally return a new character state. WARNING: the state will be asynchronously
   updated, as the `handle` callback is called in a separate process.
 - `handle_publish( {{ #'basic.deliver'{}, #amqp_msg{} }, Args}, From, State ) -> {ok, term()} | ok`: when
    publishing, the character state can be updated. `Args` are the optional arguments passed to
    `amqp_director_character:publish` function.
 - `handle_failure( { #'basic.deliver'{}, #amqp_msg{} }, State, Channel, CharPid ) -> Ignored`:
   should the handling of a message fail, this callback will be called. Useful for, e.g., `nack` Amqp or
   stats collection.
 - `publish_hook( pre, { #'basic.deliver'{}, #amqp_msg{} } ) -> { #'basic.deliver'{}, #amqp_msg{} }`:
   callback called prior to sending messages. Useful for, e.g., marshalling or message validation.
 - `deliver_hook( pre|post, { #'basic.deliver'{}, #amqp_msg{} } ) -> { #'basic.deliver'{}, #amqp_msg{} }`:
   callback called `pre` or `post` the delivery of a message.
   Useful for, e.g., marshalling, messsage validation or to `ack` Amqp.


### Adding connections and characters, the code way

Use

    amqp_director:add_connection( connection_name(), #amqp_params_network{} )

to register a connection (where `connection_name() :: atom()`).
Once at least a connection has been registered, it is possible to register characters using
the function 

    amqp_director:add_character( {character_name(), module(), term()}, connection_name() )

where the first parameter is a tuple with a character name (where `character_name() :: atom()`), module and module parameters (the latter will be passed to the `init` callback).

### Adding connections and characters, the configuration way

Set the environment variables `connections` and `characters` of the `amqp_director` application.
Both are list, here is an example:

    {connections, [ {conn_1, [{host,"localhost"}]}, {conn_2, [{username, "myuser"}, {host, "amqp.issuu.com"}]} ]}
    {characters, [
        {my_module_1, conn_1}, //character_name == module name, character args = undefined
        { {my_module_2, ["some",params]}, conn_1},
        { {another_2, my_module_2, ["other", params]}, conn_2} ]}

Each connection tuple has the connection name and a `proplist` that (as of ver.0.0.1) can specify the `host`, `port`,
`username` and `password` fields.

Each character tuple has the module name and arguments, and the connection identifier.

## Limitations

While it is easy to use the same connection for multiple characters, it is hard to use the same character with 
multiple connections.

## I was joking, here is a complete code example:

An `example_start` module could look like:

    -module(example_start).
    -compile(export_all).
    -include_lib("amqp_client/include/amqp_client.hrl").

    start() ->
        ok = application:start( amqp_client ),
        ok = application:start( amqp_director ),

        amqp_director:add_connection( myconn, #amqp_params_network{} ),
        amqp_director:add_character( {mychar1, mycharacter, [my, beautiful, 5]}, myconn ),
        amqp_director:add_character( {mychar2, mycharacter, [my, beautiful, 2]}, myconn ),

        %here you can send messages and bla bla
        amqp_director_character:publish( mychar1, { #'basic.publish'{ routing_key = "somekey" }, #amqp_msg{ payload = <<"foo">> } } ),
        ...


And the `mycharacter` module:

    -module(mycharacter).
    -behaviour (amqp_director_character).

    -include_lib("amqp_client/include/amqp_client.hrl").

    -export ([init/2, handle/4, handle_publish/3, handle_failure/4, terminate/2, publish_hook/2, deliver_hook/3]).

    queue() -> <<"my_bautiful_queue">>.

    init( Chan, [my, beautiful, Args] ) ->
        io:format("initializing module~n", []),
        BindKey = queue(),

        QDecl = #'queue.declare'{ queue = BindKey },
        #'queue.declare_ok'{
            queue = Queue
        } = amqp_channel:call(Chan, QDecl),

        io:format("Queue declared: ~p~n", [Queue]),

        BasicConsume = #'basic.consume'{ queue = BindKey },
        #'basic.consume_ok'{ consumer_tag = Tag } = amqp_channel:subscribe(Chan, BasicConsume, self()),
        {ok, Tag}. 

    handle( {#'basic.deliver'{ delivery_tag = DTag, consumer_tag = Tag }, #amqp_msg{ payload = Payload }}, Tag, Chan, CharRef ) ->
        io:format("Received: ~p~n", [binary_to_term(Payload)]),
        amqp_channel:cast(Chan, #'basic.ack'{delivery_tag = DTag}),
        % example reply
        amqp_director_character:publish( CharRef, { #'basic.publish'{}, #amqp_msg{ payload = <<"helo">> } } ),
        %
        ok.
    
    handle_publish( _Msg, _From, _State ) ->
        ok.
    handle_failure( {#'basic.deliver'{delivery_tag = DeliverTag}, _}, _State, Channel, CharRef ) ->
        io:format("Uops, someting went wrong! Let's nack the message~n", []),
        amqp_channel:cast(Channel, #'basic.nack'{delivery_tag = DeliverTag}),
        ok.

    terminate(Reason, State) ->
        io:format("Quitting because of: ~p~nWhen in state:~p~n", [Reason,State]).

    publish_hook( _Signal, Msg ) ->
        Msg.
    deliver_hook( _Signal, Msg, _Channel ) ->
        Msg.






