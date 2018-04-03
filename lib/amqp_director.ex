defmodule AmqpDirector do
  @moduledoc """
  Documentation for AmqpDirector.
  """
  require AmqpDirector.Queues

  @type connection_option ::
      {:host, String.t} |
      {:port, non_neg_integer} |
      {:username, String.t} |
      {:password, String.t} |
      {:virtual_host, String.t}
  @type connection_info :: [connection_option]

  @type content_type :: String.t
  @type handler_return_type ::  {:reply, payload :: binary, content_type} |
                                :reject |
                                :reject_no_requeue |
                                {:reject_dump_msg, String.t} |
                                :ack
  @type handler :: (payload :: binary, content_type, type :: String.t -> handler_return_type)

  @type server_option ::
      {:consume_queue, String.t} |
      {:queue_definitions, list(queue_definition)} |
      {:consumer_tag, String.t} |
      {:no_ack, boolean} |
      :qos |
      :reply_persistent

  @type client_option ::
      {:exchange, String.t} |
      {:app_id, String.t} |
      {:routing_key, String.t} |
      {:presistent, boolean} |
      :no_ack


  @type queue_definition :: exchange_declare | queue_declare | queue_bind
  @doc """
  Creates a child specification for an AMQP RPC server

  """
  @spec server_child_spec(atom, handler, connection_info, non_neg_integer, list(server_option)) :: :supervisor.child_spec
  def server_child_spec(name, handler, connectionInfo, count, config) do
    connectionInfo
    |> Keyword.update!(:host, &String.to_charlist/1)
    |> :amqp_director.parse_connection_parameters()
    |> (fn(connection) -> :amqp_director.server_child_spec(name, handler, connection, count, config) end).()
  end



  
  @typep queue_declare :: AmqpDirector.Queues.queue_declare

  @doc """

  """
  @spec queue_declare(String.t, Keyword.t) :: queue_declare
  def queue_declare(name, params \\ []) do
    passive = Access.get(params, :passive, false)
    durable = Access.get(params, :durable, false)
    exclusive = Access.get(params, :exclusive, false)
    auto_delete = Access.get(params, :auto_delete, false)
    AmqpDirector.Queues.queue_declare(queue: name, passive: passive, durable: durable, exclusive: exclusive, auto_delete: auto_delete)
  end

  @typep queue_bind :: AmqpDirector.Queues.queue_bind

  @doc """

  """
  @spec queue_bind(String.t, String.t, String.t) :: queue_bind
  def queue_bind(name, exchange, routing_key) do
    AmqpDirector.Queues.queue_bind(queue: name, exchange: exchange, routing_key: routing_key)
  end


  @typep exchange_declare :: AmqpDirector.Queues.exchange_declare

  @doc """

  """
  @spec exchange_declare(String.t, Keyword.t) :: exchange_declare
  def exchange_declare(name, params \\ []) do
    type = Keyword.get(params, :type, "direct")
    passive = Keyword.get(params, :passive, false)
    durable = Keyword.get(params, :durable, false)
    auto_delete = Keyword.get(params, :auto_delete, false)
    internal = Keyword.get(params, :internal, false)
    AmqpDirector.Queues.exchange_declare(exchange: name, passive: passive, durable: durable, type: type, auto_delete: auto_delete, internal: internal)
  end

end
