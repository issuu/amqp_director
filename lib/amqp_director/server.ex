defmodule AmqpDirector.Server do
  @moduledoc """
  The AMQP RPC Server.

  This module contains functionality for an RPC server. See `AmqpDirector.server_child_spec/3` for details on how to start the RPC server.
  """

  @doc """
  Await until the server is started.

  This will block the caller for the specified time or until the RPC server starts. This can be use to ensure that the server is running before
  continuing.
  """
  @spec await(client :: atom | pid, timeout :: pos_integer | :infinity) :: any
  def await(client, timeout \\ :infinity) do
    :amqp_rpc_server2.await(client, timeout)
  end
end
