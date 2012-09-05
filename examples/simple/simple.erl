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
    Conn = amqp_director:add_connection( local_conn, #amqp_params_network{}),
    ?log("connection added (~p)",[Conn]),
    Char = amqp_director:add_character( {myl1, mylistener, undefined}, local_conn ),
    ?log("character added (~p), now sleep...",[Char]),

    BuggyChar = amqp_director:add_character({buggycharacter,buggycharacter, undefined}, local_conn),
    ?log("character added (~p), now sleep...",[BuggyChar]),

    Char2 = amqp_director:add_character( {myl2, mylistener, undefined}, local_conn),
    ?log("character added (~p), now sleep...",[Char2]),

    timer:sleep(1000),
    ?log("and now try to send a message",[]),
    Res = mylistener:publish(myl1, "foobar"),
    ?log("published? ~p", [Res]),
    Pid = spawn(fun() -> publish_loop(0) end),
    put(pub_proc, Pid), 
    ok.

publish_loop(N) ->
    receive
        exit -> ok
    after
        500 ->
            Res0 = mylistener:publish( myl1, "foobar" ++ integer_to_list(N) ),
            ?log("res0>>~p", [Res0]),
            Res2 = mylistener:publish( myl2, "2)foobar" ++ integer_to_list(N) ),
            ?log("res0>>~p", [Res2]),
            Res1 = buggycharacter:publish( "bugme" ++ integer_to_list(N) ),
            ?log("res1>>~p", [Res1]),
            publish_loop( N+1 )
    end.

stop() ->
    ?log("close app", []),
    Pid = get(pub_proc),
    Pid ! exit,
    application:stop( amqp_director ).

amqp_params() ->
    #amqp_params_network{}.