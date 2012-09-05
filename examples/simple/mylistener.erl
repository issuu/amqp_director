-module (mylistener).
-behaviour (amqp_director_character).

% -compile(export_all).
-export ([publish/1]).
-export ([name/0, init/2, handle/3, handle_failure/3, terminate/2, publish_hook/2, deliver_hook/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

queue() -> <<"fz_test_simple">>.

publish( Payload ) ->
    Basic = #'basic.publish'{ routing_key = queue() },
    Message = #amqp_msg{ payload = term_to_binary(Payload) },

    amqp_director_character:publish(?MODULE, {Basic, Message}).

name() -> ?MODULE.
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

handle( {#'basic.deliver'{ delivery_tag = DTag, consumer_tag = Tag }, #amqp_msg{ payload = Payload }}, Tag, Chan ) ->
    io:format("Received: ~p~n", [binary_to_term(Payload)]),
    amqp_channel:cast(Chan, #'basic.ack'{delivery_tag = DTag}),
    ok.

handle_failure( _Msg, _State, _Chan) ->
    io:format("Uops, someting went wrong!~n", []),
    ok.

terminate(Reason, State) ->
    io:format("Quitting because of: ~p~nWhen in state:~p~n", [Reason,State]).

publish_hook( _Signal, Msg ) ->
    Msg.
deliver_hook( _Signal, Msg, _Channel ) ->
    Msg.