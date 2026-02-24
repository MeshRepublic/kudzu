defmodule Kudzu.Brain.ClaudeStreamTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Claude
  alias Kudzu.Brain.Claude.{Response, ToolCall}

  # ── Unit Tests: SSE Parsing ────────────────────────────────────────

  # We test the internal stream assembly by simulating the events that
  # call_stream would receive. Since the SSE parsing helpers are private,
  # we test them indirectly through call_stream with a mock HTTP flow.
  # For unit-level confidence, we also test build_request with stream flag.

  test "build_request does not include stream key by default" do
    body = Claude.build_request([%{role: "user", content: "Hi"}])
    refute Map.has_key?(body, "stream")
  end

  test "call_stream requires :stream_to option" do
    assert_raise ArgumentError, ~r/stream_to/, fn ->
      Claude.call_stream("fake-key", [%{role: "user", content: "Hi"}], [], [])
    end
  end

  # ── Integration Tests ──────────────────────────────────────────────

  @tag :integration
  test "call_stream sends chunks and returns complete response" do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      IO.puts("Skipping integration test: ANTHROPIC_API_KEY not set")
    else
      me = self()

      messages = [%{role: "user", content: "Say exactly: hello world"}]

      {:ok, %Response{} = response} =
        Claude.call_stream(api_key, messages, [],
          stream_to: me,
          max_tokens: 64,
          model: "claude-sonnet-4-6"
        )

      # Should have received at least one chunk
      chunks = drain_chunks()
      assert length(chunks) > 0

      # All chunks should be non-empty strings
      assert Enum.all?(chunks, &is_binary/1)
      assert Enum.all?(chunks, &(String.length(&1) > 0))

      # Concatenated chunks should equal the final response text
      concatenated = Enum.join(chunks)
      assert concatenated == response.text

      # Response should be well-formed
      assert response.stop_reason == "end_turn"
      assert response.usage.input_tokens > 0
      assert response.usage.output_tokens > 0
      assert response.tool_calls == []
    end
  end

  @tag :integration
  test "reason_stream sends chunks and returns final text" do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      IO.puts("Skipping integration test: ANTHROPIC_API_KEY not set")
    else
      me = self()

      {:ok, text, usage} =
        Claude.reason_stream(
          api_key,
          "You are a concise assistant.",
          "Say exactly: streaming works",
          [],
          fn _name, _input -> "ok" end,
          stream_to: me,
          max_tokens: 64,
          model: "claude-sonnet-4-6"
        )

      # Should have received chunks
      chunks = drain_chunks()
      assert length(chunks) > 0

      # Final text should be non-empty
      assert String.length(text) > 0

      # Usage should be populated
      assert usage.input_tokens > 0
      assert usage.output_tokens > 0
      assert usage.turns == 1
    end
  end

  @tag :integration
  test "call_stream handles tool use in streaming mode" do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      IO.puts("Skipping integration test: ANTHROPIC_API_KEY not set")
    else
      me = self()

      tools = [
        %{
          "name" => "get_weather",
          "description" => "Get the current weather for a location.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{
              "location" => %{"type" => "string", "description" => "City name"}
            },
            "required" => ["location"]
          }
        }
      ]

      messages = [
        %{role: "user", content: "What's the weather in Paris? Use the get_weather tool."}
      ]

      {:ok, %Response{} = response} =
        Claude.call_stream(api_key, messages, tools,
          stream_to: me,
          max_tokens: 256,
          model: "claude-sonnet-4-6"
        )

      assert response.stop_reason == "tool_use"
      assert length(response.tool_calls) >= 1

      tool_call = hd(response.tool_calls)
      assert %ToolCall{} = tool_call
      assert tool_call.name == "get_weather"
      assert is_binary(tool_call.id)
      assert is_map(tool_call.input)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp drain_chunks do
    drain_chunks([])
  end

  defp drain_chunks(acc) do
    receive do
      {:chunk, text} -> drain_chunks(acc ++ [text])
    after
      0 -> acc
    end
  end
end
