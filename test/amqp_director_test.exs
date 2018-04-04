defmodule AmqpDirectorTest do
  use ExUnit.Case
  doctest AmqpDirector

  @amqp_host "localhost"
  @amqp_username "guest"
  @amqp_password "guest"

  test "Creating RPC server spec" do
    spec = AmqpDirector.server_child_spec(
      :test_name,
      fn(_, _, _) -> :ok end,
      [host: "amqp.host", username: "test", password: "test"],
      1,
      [
        AmqpDirector.exchange_declare("my_exchange")
      ]
    )

    assert {:test_name, {:amqp_server_sup, :start_link, _},
          :permanent, :infinity, :supervisor, [:amqp_server_sup]} = spec
  end

  test "Client/server pattern" do
    serverSpec = AmqpDirector.server_child_spec(
      :test_name,
      &handler/3,
      [host: @amqp_host, username: @amqp_username, password: @amqp_password],
      2,
      [queue_definitions: [
        AmqpDirector.exchange_declare("test_exchange"),
        AmqpDirector.queue_declare("test_queue", auto_delete: true),
        AmqpDirector.queue_bind("test_queue", "test_exchange", "test_key")
      ],
      consume_queue: "test_queue"
      ]
    )
    clientSpec = AmqpDirector.client_child_spec(
      :test_client,
      [host: @amqp_host, username: @amqp_username, password: @amqp_password],
      []
    )
    Supervisor.start_link([serverSpec, clientSpec], strategy: :one_for_one)

    AmqpDirector.Client.await(:test_client)
    {:ok, "reply", "application/x-erlang-term"} = AmqpDirector.Client.call(:test_client, "test_exchange", "test_key", "some_msg", "application/x-erlang-term", [])
  end

  defp handler("some_msg", "application/x-erlang-term", "request"), do: {:reply, "reply", "application/x-erlang-term"}
  defp handler(_, _, _), do: {:reply, "wrong_msg", "application/x-erlang-term"}
end
