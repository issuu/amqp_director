-module (buggycharacter).
-behaviour (amqp_director_character).

% -compile(export_all).
-export ([publish/1]).
-export ([name/0, init/2, handle/3, handle_failure/3, terminate/2, publish_hook/2, deliver_hook/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

queue() -> <<"fz_test_buggy">>.

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
    Pid = spawn( fun() -> random_loop() end ),
    {ok, {Tag, Pid}}. 

handle( {#'basic.deliver'{ delivery_tag = DTag, consumer_tag = Tag }, #amqp_msg{ payload = Payload }}, {Tag, RPid}, Chan ) ->
    RPid ! {req, self()},
    Random = receive
        {random, R} -> R
    end,
    case Random of
        X when X < 0.4 ->
            io:format("Let it crash! (~p)~n", [binary_to_term(Payload)]),
            throw( random_crash );
        Y ->
            io:format("Received (with probability of handle: ~p): ~p~n", [Y,binary_to_term(Payload)]),
            amqp_channel:cast(Chan, #'basic.ack'{delivery_tag = DTag}),
            ok
    end.

handle_failure( {#'basic.deliver'{delivery_tag = DeliverTag}, _}, _State, Channel ) ->
    io:format("Uops, someting went wrong! Let's nack the message~n", []),
    amqp_channel:cast(Channel, #'basic.nack'{delivery_tag = DeliverTag}),
    ok.

terminate(Reason, State) ->
    io:format("Quitting because of: ~p~nWhen in state:~p~n", [Reason,State]).

publish_hook( _Signal, Msg ) ->
    Msg.
deliver_hook( _Signal, Msg, _Channel ) ->
    Msg.

random_loop() ->
    receive
        {req, From} -> From ! {random,random:uniform()}, random_loop()
    end.
