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

```elixir
connInfo = [username: "guest", password: "guest", host: "localhost", port: 5672]
args = [{"x-message-ttl", long, 30000}, {"x-dead-letter-exchange", longstr, "dead-letters"}]
config = [consume_queue: "test_queue",
          no_ack: true,
          queue_definitions: [AmqpDirector.queue_declare("test_queue", arguments: QArgs)]
        ]
```

`ConnInfo` is a local AMQP connection. The `Config` is a configuration suitable for an RPC server.

We also have to define a handler function for the server:

```elixir
defp handler("some_msg", "application/x-erlang-term", "request"), do: {:reply, "reply", "application/x-erlang-term"}
defp handler(_, _, _), do: {:reply, "wrong_msg", "application/x-erlang-term"}
```

The handler takes three parameters, the first one is the payload of the message in raw binary format, the second one is the content type as set
by the client and the third is the AMQP message type also sent by the client. If the server is to reply it must reply with the specified tuple,
indicating the payload itself and the content type. There are many more possible responses from a handler, please see the Hex documentation for details.

Now we can define a server:
```elixir
serverSpec = AmqpDirector.server_child_spec(
    :test_name,
    &handler/3,
    connInfo,
    2,
    config
  )
Supervisor.start_link([serverSpec], strategy: :one_for_one)
```

The server is now up and running under our supervisor.

A client tree can be started in a similar manner:

```elixir
clientSpec = AmqpDirector.client_child_spec(
      :test_client,
      connInfo,
      []
    )
Supervisor.start_link([serverSpec, clientSpec], strategy: :one_for_one)
```

To use the newly spawned client, you issue a call with a payload and a content type (The type will automatically be set to `<<"request">>`:

```elixir
{:ok, "reply", "application/x-erlang-term"} = AmqpDirector.Client.call(:test_client, "test_exchange", "test_key", "some_msg", "application/x-erlang-term", [])
```

Or is you don't want to wait for the response, you supply a payload, a content type, and finally
a "type" which says what kind of message this is:

```elixir
AmqpDirector.Client:cast(:test_client, <<"Hello">>, <<"application/x-erlang-term">>, <<"event">>),
```
Note that the current semantics are such that if the queue is down, then the
message is not going to be delivered to the queue. It will be black-holed instead.
This can happen if the connection to AMQP is lost and we are sitting in a reconnect
loop waiting for the connection to come back up. Then the server acts like as if
a cast without a pid().

### Erlang

All of the API is also available in Erlang via the `amqp_director` module, with almost identical format. Please see the eDoc documentation for details.
### Considerations

If you have one or two amqp rpc servers/clients, then it is probably easier just to link
them directly in your supervisor tree.

Although a connection configuration can be used many times, each server/client gets its
own connection. The sharing is only about the configuration.
