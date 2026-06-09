defmodule Kudzu.Brain.PromptBuilderTest do
  @moduledoc """
  Tests for the Phase 4.2 KnownTraces integration in the Brain prompt
  builder: same-session re-queries should emit references instead of
  full content, and a tokens-saved telemetry event should fire on each
  skip.
  """
  use ExUnit.Case, async: false

  alias Kudzu.Brain.PromptBuilder
  alias Kudzu.Cognition.KnownTraces

  defp brain_state(hologram_pid, hologram_id, opts \\ []) do
    %Kudzu.Brain{
      hologram_id: hologram_id,
      hologram_pid: hologram_pid,
      desires: Keyword.get(opts, :desires, []),
      cycle_count: 0,
      status: :reasoning,
      config: %{model: "claude-sonnet-4-20250514"}
    }
  end

  # Stand-in hologram that holds the trace map the prompt builder reads
  # via `:sys.get_state/1`. A bare Agent is enough; the prompt builder
  # doesn't care that it isn't a real Kudzu.Hologram.
  defp start_fake_hologram(traces) do
    {:ok, pid} = Agent.start_link(fn -> %{traces: traces} end)
    on_exit_cleanup(pid)
    pid
  end

  defp on_exit_cleanup(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Agent.stop(pid)
    end)
  end

  defp trace(id, purpose, content, ts) do
    %{
      id: id,
      purpose: purpose,
      reconstruction_hint: %{content: content},
      timestamp: ts
    }
  end

  describe "same-trace, same-session re-injection" do
    test "second prompt-build emits a reference for an already-seen trace" do
      hologram_id = "ph42-#{System.unique_integer([:positive])}"
      session_id = "ph42-session-#{System.unique_integer([:positive])}"

      t1 = trace("trace-aaa", :observation, "the full content of trace aaa", 1)
      pid = start_fake_hologram(%{t1.id => t1})

      state = brain_state(pid, hologram_id)

      # First call must inline the full content.
      first = PromptBuilder.build(state, session_id: session_id)
      assert first =~ "the full content of trace aaa"
      refute first =~ "[reference: trace trace-aaa"

      :ok = KnownTraces.sync()

      # Second call (same session, same model) must emit a reference.
      second = PromptBuilder.build(state, session_id: session_id)
      assert second =~ "[reference: trace trace-aaa"
      refute second =~ "the full content of trace aaa"
    end

    test "different session re-inlines the same trace" do
      hologram_id = "ph42-#{System.unique_integer([:positive])}"
      session_a = "ph42-session-A-#{System.unique_integer([:positive])}"
      session_b = "ph42-session-B-#{System.unique_integer([:positive])}"

      t1 = trace("trace-bbb", :observation, "the full content of trace bbb", 1)
      pid = start_fake_hologram(%{t1.id => t1})

      state = brain_state(pid, hologram_id)

      _ = PromptBuilder.build(state, session_id: session_a)
      :ok = KnownTraces.sync()

      out = PromptBuilder.build(state, session_id: session_b)
      assert out =~ "the full content of trace bbb"
      refute out =~ "[reference: trace trace-bbb"
    end
  end

  describe "telemetry" do
    test "tokens-saved event fires once per skipped trace" do
      hologram_id = "ph42-#{System.unique_integer([:positive])}"
      session_id = "ph42-session-#{System.unique_integer([:positive])}"

      t1 = trace("trace-ccc", :observation, "telemetry trace content body", 1)
      pid = start_fake_hologram(%{t1.id => t1})
      state = brain_state(pid, hologram_id)

      # Prime KnownTraces.
      _ = PromptBuilder.build(state, session_id: session_id)
      :ok = KnownTraces.sync()

      test_pid = self()
      handler_id = {__MODULE__, :tokens_saved, System.unique_integer()}

      :telemetry.attach(
        handler_id,
        [:kudzu, :tokens, :saved],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tokens_saved, measurements, metadata})
        end,
        nil
      )

      try do
        _ = PromptBuilder.build(state, session_id: session_id)

        assert_receive {:tokens_saved, %{count: 1, trace_tokens: tokens}, metadata}, 1_000
        assert is_integer(tokens) and tokens >= 0
        assert metadata.hologram_id == hologram_id
        assert metadata.session_id == session_id
        assert metadata.model_id == "claude-sonnet-4-20250514"
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "build_chat parity" do
    test "build_chat applies the same KnownTraces logic as build" do
      hologram_id = "ph42-#{System.unique_integer([:positive])}"
      session_id = "ph42-session-#{System.unique_integer([:positive])}"

      t1 = trace("trace-ddd", :observation, "chat-path full content", 1)
      pid = start_fake_hologram(%{t1.id => t1})
      state = brain_state(pid, hologram_id)

      first = PromptBuilder.build_chat(state, session_id: session_id)
      assert first =~ "chat-path full content"

      :ok = KnownTraces.sync()

      second = PromptBuilder.build_chat(state, session_id: session_id)
      assert second =~ "[reference: trace trace-ddd"
      refute second =~ "chat-path full content"
    end
  end
end
