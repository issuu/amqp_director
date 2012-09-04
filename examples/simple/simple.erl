-module (simple).
% -export ([start/0]).
-include_lib("amqp_client/include/amqp_client.hrl").
-define (log (Fmt, Args), io:format(Fmt++"\n", Args)).

-compile(export_all).

start() ->
    ?log("starting...",[]),
    ok = application:start( amqp_client ),
    ok = application:start( amqp_director ),
    ?log("started!",[]),
    amqp_director:add_connection( local_conn, #amqp_params_network{}),
    ?log("connection added",[]),
    amqp_director:add_character( mylistener, local_conn ),
    ?log("character added, now sleep...",[]),

    timer:sleep(1000),
    ?log("and now try to send a message",[]),
    Res = mylistener:publish("foobar"),
    ?log("pusblished? ~p", [Res]),

    timer:sleep(5000),
    ?log("close app", []),
    application:stop( amqp_director ).

amqp_params() ->
    #amqp_params_network{}.