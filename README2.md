# AMQP Director
## A simplistic embeddable RPC Client/Server library for AMQP/RabbitMQ.

AMQP director implements two very common patterns for AMQP/RabbitMQ in a robust way.

First, it implements a server-pattern: Messages are consumed from a queue `QIn`.
They are fed through a function `F` and then the result is posted on a result queue
`QOut` as determined by the message. The server pattern essentially turns an Erlang
function into a processor of AMQP messages. To get scalability and concurrency a static pool of
function workers are kept around to handle multiple incoming messages.

Second, the library implements a typical RPC client pattern: A process `P` wants to call an RPC
service. It then issues an OTP `call` to a client gen_server and thus blocks until there is a
response, or the call times out. The semantics have been kept as much as possible to reflect
that of a typical `gen_server` in Erlang. The `gen_server` maintaining the AMQP messaging does
not block, so we have experienced message rates of 8000 reqs/s on a single queue with a single
`gen_server` easily.

Third, the library provides two other common patterns: for the server, it allows for non-response
operation. That is, you consume messages off of a queue, but you don't provide a response back.
For the client, the library supports fire'n'forget messages where you just send a message and
don't care about it anymore.

## Usage:

The library exposes two supervisors, intended for embedding into another supervisor tree of your
choice, so the link becomes part of your application. Suppose we have:

	ConnInfo = #amqp_params_network { username = <<"guest">>, password = <<"guest">>,
		                                  host = "localhost", port = 5672 },

Which is a local AMQP connection. Now we can define a server:
			                                  
	{ok, SPid} = amqp_server_sup:start_link(
	    server_connection_mgr, ConnInfo, <<"test_queue">>,
	    [{<<"x-message-ttl">>, long, 30000},
	     {<<"x-dead-letter-exchange">>, longstr, <<"dead-letters">>}], F, 5),

This gives us back a supervisor tree where we have a queue `<<"test_queue">>`, configured
with a time out and a dead-letter support. We have defined that the function identified by
`F` should be run upon message consumption and that we want 5 static workers. F could look
like

	-spec f(binary()) -> {reply, binary()} | ack | reject | reject_no_requeue.
	f(_Request) ->
	  {reply, <<"ok">>}.

which will just consume any message and produce an "Ok" response. Note the other return possibilities.
You can `ack` the message if you don't want to reply with anything. You can `reject` the message which
means it will be requeued again for someone else to consume. You can also `reject_no_requeue` if you
want to reject the request and not have it requeued. The semantics then depend on dead-lettering of the
AMQP queue.

A client tree can be started with the following piece of code

	{ok, CPid} = amqp_client_sup:start_link(
	    client_connection, client_connection_mgr, 
	    ConnInfo, <<"test_queue">>),

which will start up a client, registered on the name `client_connection`. The `client_connection_mgr`
is the registered name of the connection manager process so you can alter that to your liking. The
`<<"test_queue">>` is a `RoutingKey` which tells AMQP where to route the message (what exchange to hit,
normally).

To use the newly spawned client, you issue a call:

	amqp_rpc_client2:call(client_connection, <<"Hello">>),

Or is you don't want to wait for the response:

	amqp_rpc_client2:cast(client_connection, <<"Hello">>),

Note that the current semantics are such that if the queue is down, then the
message is not going to be delivered to the queue. It will be black-holed instead.
This can happen if the connection to AMQP is lost and we are sitting in a reconnect
loop waiting for the connection to come back up. Then the server acts like as if
a cast without a pid().