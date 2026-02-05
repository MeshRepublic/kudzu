defmodule Kudzu.ProtocolTest do
  use ExUnit.Case, async: true

  alias Kudzu.{Protocol, VectorClock, Trace}

  describe "message constructors" do
    test "ping creates valid message" do
      clock = VectorClock.new("agent-1")
      msg = Protocol.ping("agent-1", clock)

      assert msg.type == :ping
      assert msg.origin == "agent-1"
      assert Protocol.valid?(msg)
    end

    test "query includes purpose and max_hops" do
      clock = VectorClock.new("agent-1")
      msg = Protocol.query("agent-1", clock, :memory, 5)

      assert msg.type == :query
      assert msg.purpose == :memory
      assert msg.max_hops == 5
    end

    test "trace_share includes trace" do
      clock = VectorClock.new("agent-1")
      trace = Trace.new("agent-1", :test)
      msg = Protocol.trace_share("agent-1", clock, trace)

      assert msg.type == :trace_share
      assert msg.trace == trace
    end
  end

  describe "encode/decode" do
    test "roundtrips simple message" do
      clock = VectorClock.new("agent-1") |> VectorClock.increment("agent-1")
      original = Protocol.ping("agent-1", clock)

      {:ok, encoded} = Protocol.encode(original)
      {:ok, decoded} = Protocol.decode(encoded)

      assert decoded.type == original.type
      assert decoded.origin == original.origin
    end

    test "roundtrips message with trace" do
      clock = VectorClock.new("agent-1")
      trace = Trace.new("agent-1", :memory, ["agent-1"], %{key: "value"})
      original = Protocol.trace_share("agent-1", clock, trace)

      {:ok, encoded} = Protocol.encode(original)
      {:ok, decoded} = Protocol.decode(encoded)

      assert decoded.trace.origin == trace.origin
      assert decoded.trace.purpose == trace.purpose
      assert decoded.trace.reconstruction_hint == trace.reconstruction_hint
    end

    test "roundtrips query response with traces" do
      clock = VectorClock.new("agent-1")
      traces = [
        Trace.new("agent-1", :test, ["agent-1"]),
        Trace.new("agent-2", :test, ["agent-2"])
      ]
      original = Protocol.query_response("agent-1", clock, traces, ["agent-3"])

      {:ok, encoded} = Protocol.encode(original)
      {:ok, decoded} = Protocol.decode(encoded)

      assert length(decoded.traces) == 2
      assert decoded.suggested_peers == ["agent-3"]
    end
  end

  describe "validation" do
    test "valid? returns true for well-formed messages" do
      clock = VectorClock.new("agent-1")
      msg = Protocol.ping("agent-1", clock)
      assert Protocol.valid?(msg)
    end

    test "valid? returns false for malformed messages" do
      refute Protocol.valid?(%{type: :ping})
      refute Protocol.valid?(%{type: :ping, origin: 123, timestamp: %{}})
    end
  end

  describe "causality comparison" do
    test "compares message timestamps" do
      clock1 = VectorClock.new("a") |> VectorClock.increment("a")
      clock2 = clock1 |> VectorClock.increment("a")

      msg1 = Protocol.ping("a", clock1)
      msg2 = Protocol.ping("a", clock2)

      # msg1 happened before msg2
      assert Protocol.compare_causality(msg1, msg2) == :before
    end
  end
end
