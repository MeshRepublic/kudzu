defmodule Kudzu.Brain.SelfConverseTest do
  @moduledoc """
  Tests the skeleton contract of Brain.SelfConverse. Implementation is
  deferred; these tests verify the interface is callable and the
  not-implemented bodies behave correctly.
  """
  use ExUnit.Case, async: true

  alias Kudzu.Brain.SelfConverse

  describe "loop_step/3" do
    test "raises with a clear :not_implemented message" do
      assert_raise RuntimeError, ~r/not implemented/i, fn ->
        SelfConverse.loop_step(%{}, "prior thought", 0)
      end
    end
  end

  describe "converged?/1" do
    test "raises with a clear :not_implemented message" do
      assert_raise RuntimeError, ~r/not implemented/i, fn ->
        SelfConverse.converged?(%{})
      end
    end
  end

  describe "depth ceiling enforcement" do
    test "max_depth/0 returns the configured max (default 10)" do
      assert SelfConverse.max_depth() == 10
    end
  end
end
