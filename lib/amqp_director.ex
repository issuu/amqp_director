defmodule AmqpDirector do
  @moduledoc """
  Documentation for AmqpDirector.
  """

  @type connection_option ::
      {:host, String.t()} |
      {:port, non_neg_integer()} |
      {:username, String.t()} |
      {:password, String.t()} |
      {:virtual_host, String.t()}
  @type connection_info :: [connection_option]

  @type content_type :: String.t
  @type handler_return_type ::  {:reply, payload :: binary, content_type} |
                                :reject |
                                :reject_no_requeue |
                                {:reject_dump_msg, String.t} |
                                :ack
  @type handler :: (payload :: binary, content_type, type :: String.t -> handler_return_type)

  @doc """
  Creates a child specification for an AMQP RPC server

  """
  @spec server_child_spec(atom, handler, connection_info, non_neg_integer, list(term)) :: :supervisor.child_spec
  def server_child_spec(name, handler, connectionInfo, count, config) do
    connectionInfo
    |> Keyword.update!(:host, &String.to_charlist/1)
    |> :amqp_director.parse_connection_parameters()
    |> (fn(connection) -> :amqp_director.server_child_spec(name, handler, connection, count, config) end).()
  end
end
