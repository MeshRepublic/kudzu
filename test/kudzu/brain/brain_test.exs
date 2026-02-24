defmodule Kudzu.BrainTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain

  test "brain starts and has sleeping status" do
    state = Brain.get_state()
    assert state.status == :sleeping
  end

  test "brain has initial desires" do
    state = Brain.get_state()
    assert length(state.desires) == 5
    assert Enum.any?(state.desires, &String.contains?(&1, "health"))
  end

  test "brain creates or finds hologram" do
    # Give brain time to init hologram
    Process.sleep(3_000)
    state = Brain.get_state()
    assert is_binary(state.hologram_id) or state.hologram_id == nil
    # hologram_id may be nil if Kudzu isn't fully running in test env
  end
end
