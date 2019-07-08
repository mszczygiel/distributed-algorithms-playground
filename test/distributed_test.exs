defmodule DistributedTest do
  use ExUnit.Case
  doctest Distributed

  test "greets the world" do
    assert Distributed.hello() == :world
  end
end
