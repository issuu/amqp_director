defmodule AmqpDirectorTest do
  use ExUnit.Case
  doctest AmqpDirector

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
end
