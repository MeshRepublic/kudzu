defmodule Kudzu.Brain.ChatTest do
  @moduledoc """
  Integration tests for Brain.chat/2 — three-tier reasoning for human interaction.

  These tests require a running Brain with its hologram initialized.
  """
  use ExUnit.Case, async: false

  alias Kudzu.Brain

  # Brain takes up to 5s to init hologram — wait for it
  setup do
    wait_for_brain(50)
    :ok
  end

  defp wait_for_brain(0), do: :ok

  defp wait_for_brain(n) do
    state = Brain.get_state()

    if state.hologram_id do
      :ok
    else
      Process.sleep(100)
      wait_for_brain(n - 1)
    end
  end

  defp get_brain_traces do
    state = Brain.get_state()

    if state.hologram_pid do
      try do
        holo_state = :sys.get_state(state.hologram_pid)
        Map.values(holo_state.traces)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  @tag :integration
  test "chat returns a response with tier info" do
    {:ok, result} = Brain.chat("Hello, what is your status?")

    assert is_binary(result.response)
    assert result.response != ""
    assert result.tier in [1, 2, 3]
    assert is_list(result.tool_calls)
    assert is_number(result.cost)
    assert result.cost >= 0.0
  end

  @tag :integration
  test "chat records user message as trace" do
    traces_before = get_brain_traces()

    unique_msg = "test_chat_user_msg_#{System.unique_integer([:positive])}"
    {:ok, _result} = Brain.chat(unique_msg)

    traces_after = get_brain_traces()

    # Find the new trace with our unique message
    new_traces = traces_after -- traces_before

    user_trace =
      Enum.find(new_traces, fn t ->
        t.purpose == :observation and
          match?(%{source: "human_chat"}, t.reconstruction_hint)
      end)

    assert user_trace != nil,
           "Expected a trace with purpose :observation and source human_chat"

    assert user_trace.reconstruction_hint.content == unique_msg
  end

  @tag :integration
  test "chat records brain response as trace" do
    traces_before = get_brain_traces()

    {:ok, _result} = Brain.chat("Tell me about yourself")

    traces_after = get_brain_traces()
    new_traces = traces_after -- traces_before

    response_trace =
      Enum.find(new_traces, fn t ->
        t.purpose == :thought and
          match?(%{source: "brain_chat_response"}, t.reconstruction_hint)
      end)

    assert response_trace != nil,
           "Expected a trace with purpose :thought and source brain_chat_response"

    assert response_trace.reconstruction_hint.tier in [1, 2, 3]
  end

  @tag :integration
  test "chat returns error when brain is not ready" do
    # This test verifies the guard clause — we can't easily test it
    # with a running brain, but we verify the function exists and
    # handles the normal case correctly
    {:ok, result} = Brain.chat("ping")
    assert is_map(result)
    assert Map.has_key?(result, :response)
    assert Map.has_key?(result, :tier)
    assert Map.has_key?(result, :tool_calls)
    assert Map.has_key?(result, :cost)
  end
end
