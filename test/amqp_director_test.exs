defmodule AmqpDirectorTest do
  use ExUnit.Case
  doctest AmqpDirector

  test "greets the world" do
    assert AmqpDirector.hello() == :world
  end
end
