defmodule AmqpDirector do
  @moduledoc """
  Documentation for AmqpDirector.
  """

  @type connection_info :: [host: String.t(),
port: non_neg_integer() | :undefined,
username: String.t(),
password: String.t(),
virtual_host: String.t() | :undefined]

  def server_child_spec(name, handler, connectionInfo, count, config) do
    connectionInfo
    |> Keyword.update!(:host, &String.to_charlist/1)
    |> :amqp_director.parse_connection_parameters()
    |> (fn(connection) -> :amqp_director.server_child_spec(name, handler, connection, count, config) end).()
  end

  @doc """
  Hello world.

  ## Examples

      iex> AmqpDirector.hello
      :world

  """
  def hello do
    :world
  end
end
