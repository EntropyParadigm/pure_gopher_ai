defmodule PureGopherAiTest do
  use ExUnit.Case
  doctest PureGopherAi

  test "greets the world" do
    assert PureGopherAi.hello() == :world
  end
end
