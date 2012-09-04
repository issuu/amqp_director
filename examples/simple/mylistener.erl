-module (mylistener).
-behaviour (amqp_director_character).

-compile(export_all).

-include_lib("amqp_client/include/amqp_client.hrl").

queue() -> <<"fz_test_simple">>.

publish( Payload ) ->
    Basic = #'basic.publish'{ routing_key = queue() },
    Message = #amqp_msg{ payload = term_to_binary(Payload) },

    amqp_director_character:publish(?MODULE, {Basic, Message}).

name() -> ?MODULE.
init( Chan ) ->
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

handle( {#'basic.deliver'{ delivery_tag = DTag, consumer_tag = Tag }, #amqp_msg{ payload = Payload }}, Tag, Chan ) ->
    io:format("Received: ~p~n", [binary_to_term(Payload)]),
    amqp_channel:cast(Chan, #'basic.ack'{delivery_tag = DTag}),
    ok.

handle_failure( _Msg, _State, _Chan) ->
    io:format("Uops, someting went wrong!~n", []),
    ok.

terminate(Reason, _State) ->
    io:format("Quitting because of: ~p~n", [Reason]).

publish_hook( _Signal, Msg ) ->
    Msg.
deliver_hook( _Signal, Msg, _Channel ) ->
    Msg.