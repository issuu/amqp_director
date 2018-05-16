defmodule AmqpDirector.PullClient do
  @moduledoc """
  The AMQP RPC pull client.

  The pull client is meant to be used for pulling information over AMQP using `:'basic.get'`. See `AmqpDirector.pull_client_child_spec/3`
  for details on how to start the client.
  """

  @doc """
  Query the queue for data.

  Sends a request to pull data from the queue. Returns `:empty` if no data is present.
  """
  @spec pull(client :: atom | pid, queue :: String.t()) :: {:ok, binary} | :empty
  def pull(client, queue) do
    :sp_client.pull(client, queue)
  end
end
