defmodule AmqpDirectorTest do
  use ExUnit.Case
  doctest AmqpDirector

  @amqp_host "localhost"
  @amqp_username "guest"
  @amqp_password "guest"

  test "Creating RPC server spec" do
    spec =
      AmqpDirector.server_child_spec(
        :test_name,
        fn _, _, _ -> :ok end,
        [host: "amqp.host", username: "test", password: "test"],
        1,
        [
          AmqpDirector.exchange_declare("my_exchange")
        ]
      )

    assert %{
             id: :test_name,
             start: {:amqp_server_sup, :start_link, _},
             restart: :permanent,
             shutdown: :infinity,
             type: :supervisor,
             modules: [:amqp_server_sup]
           } = spec
  end

  test "Client/server pattern" do
    :ets.new(:counter, [:public, :named_table])

    serverSpec =
      AmqpDirector.server_child_spec(
        :test_name,
        &handler/3,
        [host: @amqp_host, username: @amqp_username, password: @amqp_password],
        2,
        queue_definitions: [
          AmqpDirector.exchange_declare("test_exchange"),
          AmqpDirector.queue_declare("ex_test_queue", auto_delete: true),
          AmqpDirector.queue_bind("ex_test_queue", "test_exchange", "test_key")
        ],
        consume_queue: "ex_test_queue"
      )

    clientSpec =
      AmqpDirector.client_child_spec(
        :test_client,
        [host: @amqp_host, username: @amqp_username, password: @amqp_password],
        []
      )

    {:ok, _} = Supervisor.start_link([serverSpec, clientSpec], strategy: :one_for_one)

    AmqpDirector.Client.await(:test_client)

    :ok =
      AmqpDirector.Client.cast(
        :test_client,
        "test_exchange",
        "test_key",
        "some_msg",
        "application/x-erlang-term",
        "event",
        []
      )

    {:ok, "reply", "application/x-erlang-term"} =
      AmqpDirector.Client.call(
        :test_client,
        "test_exchange",
        "test_key",
        "some_msg",
        "application/x-erlang-term",
        timeout: 500
      )

    Process.sleep(1000)
    values = :ets.lookup(:counter, :key)
    2 = values[:key]
  end

  defp handler(msg, contentType, eventType) do
    :ets.update_counter(:counter, :key, 1, {:value, 0})

    case {msg, contentType, eventType} do
      {"some_msg", "application/x-erlang-term", "request"} ->
        {:reply, "reply", "application/x-erlang-term"}

      _ ->
        {:reply, "wrong_msg", "application/x-erlang-term"}
    end
  end
end
