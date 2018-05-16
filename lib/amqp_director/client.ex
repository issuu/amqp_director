defmodule AmqpDirector.Client do
  @moduledoc """
  The AMQP RPC Client.

  This module contains functionality for an RPC client. See `AmqpDirector.client_child_spec/3` for details on how to start the RPC client.
  """

  @typedoc """
  Options for an RPC request.

  * `:timeout` - Time the client awaits response. Only valid for `call/6`
  * `:persistent` - Specifies the delivery mode for the AMQP messages. Setting this to `true` will make the broker log the
  messages on disk. See AMQP specification for more information. Defaults to `false`
  """
  @type request_options :: {:timeout, pos_integer} | {:persistent, boolean}

  @doc """
  Await until the client is started.

  This will block the caller for the specified time or until the RPC client starts. This can be use to ensure that the client is running before
  requests are made.
  """
  @spec await(client :: atom | pid, timeout :: pos_integer | :infinity) :: any
  def await(client, timeout \\ :infinity) do
    :ad_client.await(client, timeout)
  end

  @doc """
  Send an asynchronous request.

  Sends an asynchronous request to an AMQP broker without expecting any response. It is send to the specified exchange using the specified routing key.
  The `content_type` specifies the type of the payload while the `type` parameters refers to the AMQP message type header. See the AMQP reference for
  details.
  """
  @spec cast(
          client :: atom | pid,
          exchange :: String.t(),
          routing_key :: String.t(),
          payload :: binary,
          content_type :: String.t(),
          type :: String.t(),
          options :: list(request_options)
        ) :: :ok
  def cast(client, exchange, routing_key, payload, content_type, type, options \\ []) do
    :ad_client.cast(client, exchange, routing_key, payload, content_type, type, options)
  end

  @typedoc "Error types for the synchronous RPC call."
  @type call_error_reason :: :no_route | :no_consumers | {:reply_code, number}

  @doc """
  Send a synchronous request.

  Sends a synchronous request to an AMQP broker and awaits for response for the length of `:timeout` option (Defaults to 5 seconds). It sends the message
  to the specified exchange with the specified routing key. The `content_type` specifies the type of the payload. AMQP message type is always set to
  `"request"` in case of a call.
  """
  @spec call(
          client :: atom | pid,
          exchange :: String.t(),
          routing_key :: String.t(),
          payload :: binary,
          content_type :: String.t(),
          options :: list(request_options)
        ) :: {:ok, content :: binary, content_type :: String.t()} | {:error, call_error_reason}
  def call(client, exchange, routing_key, payload, content_type, options \\ [timeout: 5000]) do
    :ad_client.call(client, exchange, routing_key, payload, content_type, options)
  end
end
