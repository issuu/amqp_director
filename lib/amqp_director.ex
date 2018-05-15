defmodule AmqpDirector do
  @moduledoc """
  Documentation for AmqpDirector.

  This module provides wrapping for the Erlang code and is intended to be used with Elixir applications.
  """
  require AmqpDirector.Queues

  @typedoc "RabbitMQ broker connection options."
  @type connection_option ::
      {:host, String.t} |
      {:port, non_neg_integer} |
      {:username, String.t} |
      {:password, String.t} |
      {:virtual_host, String.t}

  @typedoc "The content type of the AMQP message payload."
  @type content_type :: String.t

  @typedoc "The type that a AMQP RPC Server handler function must return."
  @type handler_return_type ::  {:reply, payload :: binary, content_type} |
                                :reject |
                                :reject_no_requeue |
                                {:reject_dump_msg, String.t} |
                                :ack

  @typedoc "The handler function type for the AMQP RPC Server."
  @type handler :: (payload :: binary, content_type, type :: String.t -> handler_return_type)

  @typedoc """
  AMQP RPC Server configuration options.

  * `:consume_queue` - Specifies the name of the queue on which the server will consume messages.
  * `:consumer_tag` - Specifies the tag that the server will be identified when listening on the queue.
  * `:queue_definition` - A list of instructions for setting up the queues and exchanges. The RPC Server will call these during its
    initialization. The instructions should be created using `exchange_declare/2`, `queue_declare/2` and `queue_bind/3`. E.g.
    ```
      {:queue_definitions, [
        AmqpDirector.exchange_declare("my_exchange", type: "topic"),
        AmqpDirector.queue_declare("my_queue", exclusive: true),
        AmqpDirector.queue_bind("my_queue", "my_exchange", "some.topic.*")
      ]}
    ```
  * `:no_ack` - Specifies if the server should _NOT_ auto-acknowledge consumed messages. Defaults to `false`.
  * `:qos` - Specifies the prefetch count on the consume queue. Defaults to `2`.
  * `:reply_persistent` - Specifies the delivery mode for the AMQP replies. Setting this to `true` will make the broker log the
    messages on disk. See AMQP specification for more information. Defaults to `false`
  """
  @type server_option ::
      {:consume_queue, String.t} |
      {:consumer_tag, String.t} |
      {:queue_definitions, list(queue_definition)} |
      {:no_ack, boolean} |
      {:qos, number} |
      {:reply_persistent, boolean}

  @typedoc """
  AMQP RPC Client configuraion options.

  * `:app_id` - Specifies the identitifier of the client.
  * `:queue_definition` - A list of instructions for setting up the queues and exchanges. The RPC Client will call these during its
  initialization. The instructions should be created using `exchange_declare/2`, `queue_declare/2` and `queue_bind/3`. E.g.
  ```
    {:queue_definitions, [
      AmqpDirector.exchange_declare("my_exchange", type: "topic"),
      AmqpDirector.queue_declare("my_queue", exclusive: true),
      AmqpDirector.queue_bind("my_queue", "my_exchange", "some.topic.*")
    ]}
  ```
  * `:reply_queue` - Allows naming for the reply queue. Defaults to empty name, making the RabbitMQ broker auto-generate the name.
  * `:no_ack` - Specifies if the client should _NOT_ auto-acknowledge replies. Defaults to `false`.
  """
  @type client_option ::
      {:app_id, String.t} |
      {:queue_definitions, list(queue_definition)} |
      {:reply_queue, String.t} |
      {:no_ack, boolean}

  @typedoc """
  AMQP RPC Pull Client configuraion options.

  * `:app_id` - Specifies the identitifier of the client.
  * `:queue_definition` - A list of instructions for setting up the queues and exchanges. The RPC Client will call these during its
  initialization. The instructions should be created using `exchange_declare/2`, `queue_declare/2` and `queue_bind/3`. E.g.
  ```
    {:queue_definitions, [
      AmqpDirector.exchange_declare("my_exchange", type: "topic"),
      AmqpDirector.queue_declare("my_queue", exclusive: true),
      AmqpDirector.queue_bind("my_queue", "my_exchange", "some.topic.*")
    ]}
  ```
  """
  @type pull_client_option ::
  {:app_id, String.t} |
  {:queue_definitions, list(queue_definition)}

  @typedoc "Queue definition instructions."
  @type queue_definition :: exchange_declare | queue_declare | queue_bind

  @doc """
  Creates a child specification for an AMQP RPC server.

  This specification allows for RPC servers to be nested under any supervisor in the application using AmqpDirector. The RPC Server
  will initialize the queues it is instructed to and will then consume messages on the queue specified. The handler function will
  be called to handle each request. See `t:server_option/0` for configuration options and `t:handler/0` for the type spec
  of the handler function.

  The server handles reconnecting by itself.
  """
  @spec server_child_spec(atom, handler, list(connection_option), non_neg_integer, list(server_option)) :: Supervisor.child_spec
  def server_child_spec(name, handler, connectionInfo, count, config) do
    connectionInfo
    |> Keyword.update!(:host, &String.to_charlist/1)
    |> :amqp_director.parse_connection_parameters()
    |> (fn(connection) -> :amqp_director.server_child_spec(name, handler, connection, count, config) end).()
    |> old_spec_to_new
  end

  @doc """
  Creates a child specification for an AMQP RPC client.

  This specification allows for RPC clients to be nested under any supervisor in the application using AmqpDirector. The RPC
  client can perform queue initialization. It will also create a reply queue to consume replies on. The client can then be used
  using `AmqpDirector.Client` module API. See `t:client_option/0` for configuration options.

  The client handles reconnecting by itself.
  """
  @spec client_child_spec(atom, list(connection_option), list(client_option)) :: Supervisor.child_spec
  def client_child_spec(name,  connectionInfo, config) do
    connectionInfo
    |> Keyword.update!(:host, &String.to_charlist/1)
    |> :amqp_director.parse_connection_parameters()
    |> (fn(connection) -> :amqp_director.ad_client_child_spec(name, connection, config) end).()
    |> old_spec_to_new
  end


  @doc """
  Creates a child specification for an AMQP RPC pull client.

  This specification allows for RPC clients to be nested under any supervisor in the application using AmqpDirector. The pull client
  uses the Synchronous Pull (`#basic.get{}`) over AMQP. The client can then be used using `AmqpDirector.PullClient` module API.
  See `t:pull_client_option/0` for configuration options.

  The client handles reconnecting by itself.
  """
  @spec pull_client_child_spec(atom, list(connection_option), list(pull_client_option)) :: Supervisor.child_spec
  def pull_client_child_spec(name,  connectionInfo, config) do
    connectionInfo
    |> Keyword.update!(:host, &String.to_charlist/1)
    |> :amqp_director.parse_connection_parameters()
    |> (fn(connection) -> :amqp_director.sp_client_child_spec(name, connection, config) end).()
    |> old_spec_to_new
  end


  @typep queue_declare :: AmqpDirector.Queues.queue_declare

  @doc """
  Declares a queue on the AMQP Broker.

  This function is intended to be using within `:queue_definitions` configuration parameter of a client or a server. See
  `t:client_option/0` or `t:server_option/0` for details.

  Available options are: `:passive`, `:durable`, `:exclusive`, `:auto_delete` and `:arguments`. See AMQP specification for details on
  queue declaration.
  """
  @spec queue_declare(String.t, Keyword.t) :: queue_declare
  def queue_declare(name, params \\ []) do
    passive = Access.get(params, :passive, false)
    durable = Access.get(params, :durable, false)
    exclusive = Access.get(params, :exclusive, false)
    auto_delete = Access.get(params, :auto_delete, false)
    arguments = Access.get(params, :arguments, [])
    AmqpDirector.Queues.queue_declare(queue: name, passive: passive, durable: durable, exclusive: exclusive, auto_delete: auto_delete, arguments: arguments)
  end

  @typep queue_bind :: AmqpDirector.Queues.queue_bind

  @doc """
  Binds a queue to an exchange.

  This function is intended to be using within `:queue_definitions` configuration parameter of a client or a server. See
  `t:client_option/0` or `t:server_option/0` for details. See AMQP specification for details of queue binding.
  """
  @spec queue_bind(String.t, String.t, String.t) :: queue_bind
  def queue_bind(name, exchange, routing_key) do
    AmqpDirector.Queues.queue_bind(queue: name, exchange: exchange, routing_key: routing_key)
  end


  @typep exchange_declare :: AmqpDirector.Queues.exchange_declare

  @doc """
  Declares an exchange on the AMQP Broker.

  This function is intended to be using within `:queue_definitions` configuration parameter of a client or a server. See
  `t:client_option/0` or `t:server_option/0` for details.

  Available options are: `:passive`, `:durable`, `:auto_delete`, `:internal` and `:arguments`. See AMQP specification for details on exchange
  declaration.
  """
  @spec exchange_declare(String.t, Keyword.t) :: exchange_declare
  def exchange_declare(name, params \\ []) do
    type = Keyword.get(params, :type, "direct")
    passive = Keyword.get(params, :passive, false)
    durable = Keyword.get(params, :durable, false)
    auto_delete = Keyword.get(params, :auto_delete, false)
    internal = Keyword.get(params, :internal, false)
    arguments = Access.get(params, :arguments, [])
    AmqpDirector.Queues.exchange_declare(exchange: name, passive: passive, durable: durable, type: type, auto_delete: auto_delete, internal: internal, arguments: arguments)
  end

  defp old_spec_to_new({name, start, restart, shutdown, type, modules}), do: %{id: name, start: start, restart: restart, shutdown: shutdown, type: type, modules: modules}

end
