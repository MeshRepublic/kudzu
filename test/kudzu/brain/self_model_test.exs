defmodule Kudzu.Brain.SelfModelTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.SelfModel
  alias Kudzu.Silo

  setup do
    # Clean up any existing self silo for a clean test
    Silo.delete("self")
    Process.sleep(100)

    on_exit(fn ->
      Silo.delete("self")
    end)

    :ok
  end

  describe "init/0" do
    test "creates the self silo" do
      assert :ok = SelfModel.init()
      assert {:ok, pid} = Silo.find("self")
      assert is_pid(pid)
    end

    test "seeds architecture knowledge" do
      SelfModel.init()
      results = SelfModel.query("kudzu")
      assert length(results) > 0

      subjects =
        Enum.map(results, fn {hint, _sim} ->
          Map.get(hint, :subject, Map.get(hint, "subject"))
        end)

      assert "kudzu" in subjects
    end
  end

  describe "query/1" do
    test "returns results for seeded concepts" do
      SelfModel.init()

      storage_results = SelfModel.query("storage")
      assert length(storage_results) > 0

      encoder_results = SelfModel.query("encoder")
      assert length(encoder_results) > 0
    end
  end

  describe "observe/3" do
    test "adds new knowledge to the self-model" do
      SelfModel.init()

      assert {:ok, _trace} = SelfModel.observe("brain", "learned", "new_pattern")

      results = SelfModel.query("brain")
      relations =
        Enum.map(results, fn {hint, _sim} ->
          Map.get(hint, :relation, Map.get(hint, "relation"))
        end)

      assert "learned" in relations
    end
  end
end
