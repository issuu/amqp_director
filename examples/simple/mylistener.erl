-module (mylistener).
-behaviour (amqp_director_character).

% -compile(export_all).
-export ([publish/2]).
-export ([init/2, handle/4, handle_publish/3, handle_failure/4, terminate/2, publish_hook/3, deliver_hook/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

queue() -> <<"fz_test_simple">>.

publish( Name, Payload ) ->
    Basic = #'basic.publish'{ routing_key = queue() },
    Message = #amqp_msg{ payload = term_to_binary(Payload) },

    amqp_director_character:publish(Name, {Basic, Message}).

init( Chan, _Args ) ->
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

handle_publish( _Msg, _From, _State ) -> ok.
handle( {#'basic.deliver'{ delivery_tag = DTag, consumer_tag = Tag }, #amqp_msg{ payload = Payload }}, Tag, Chan, _Ref ) ->
    io:format("Received: ~p~n", [binary_to_term(Payload)]),
    amqp_channel:cast(Chan, #'basic.ack'{delivery_tag = DTag}),
    ok.

handle_failure( _Msg, _State, _Chan, _Ref) ->
    io:format("Uops, someting went wrong!~n", []),
    ok.

terminate(Reason, State) ->
    io:format("Quitting because of: ~p~nWhen in state:~p~n", [Reason,State]).

publish_hook( _Signal, Msg, _State ) ->
    Msg.
deliver_hook( _Signal, Msg, _Channel ) ->
    Msg.