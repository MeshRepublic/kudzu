defmodule Kudzu.Protocol do
  @moduledoc """
  Protocol definitions for hologram communication.

  All messages carry:
  - Sender origin (agent_id)
  - Causal timestamp (vector clock)
  - Type-specific payload

  Designed for future network transport with encode/decode functions.
  """

  alias Kudzu.{VectorClock, Trace}

  @type message_type :: :ping | :pong | :query | :query_response |
                        :trace_share | :ack | :reconstruction_request |
                        :reconstruction_response

  @type message :: map()

  # Message Constructors

  @doc """
  Create a ping message for liveness/discovery.
  """
  @spec ping(String.t(), VectorClock.t()) :: message()
  def ping(origin, clock) do
    %{
      type: :ping,
      origin: origin,
      timestamp: VectorClock.increment(clock, origin)
    }
  end

  @doc """
  Create a pong response.
  """
  @spec pong(String.t(), VectorClock.t()) :: message()
  def pong(origin, clock) do
    %{
      type: :pong,
      origin: origin,
      timestamp: clock
    }
  end

  @doc """
  Create a query message to search for traces by purpose.
  """
  @spec query(String.t(), VectorClock.t(), atom() | String.t(), non_neg_integer()) :: message()
  def query(origin, clock, purpose, max_hops \\ 3) do
    %{
      type: :query,
      origin: origin,
      timestamp: VectorClock.increment(clock, origin),
      purpose: purpose,
      max_hops: max_hops
    }
  end

  @doc """
  Create a query response with found traces and suggested peers.
  """
  @spec query_response(String.t(), VectorClock.t(), [Trace.t()], [String.t()]) :: message()
  def query_response(origin, clock, traces, suggested_peers \\ []) do
    %{
      type: :query_response,
      origin: origin,
      timestamp: clock,
      traces: traces,
      suggested_peers: suggested_peers
    }
  end

  @doc """
  Create a trace share message.
  """
  @spec trace_share(String.t(), VectorClock.t(), Trace.t()) :: message()
  def trace_share(origin, clock, trace) do
    %{
      type: :trace_share,
      origin: origin,
      timestamp: VectorClock.increment(clock, origin),
      trace: trace
    }
  end

  @doc """
  Create an acknowledgment message.
  """
  @spec ack(String.t(), VectorClock.t()) :: message()
  def ack(origin, clock) do
    %{
      type: :ack,
      origin: origin,
      timestamp: clock
    }
  end

  @doc """
  Create a reconstruction request for a specific trace.
  """
  @spec reconstruction_request(String.t(), VectorClock.t(), String.t()) :: message()
  def reconstruction_request(origin, clock, trace_id) do
    %{
      type: :reconstruction_request,
      origin: origin,
      timestamp: VectorClock.increment(clock, origin),
      trace_id: trace_id
    }
  end

  @doc """
  Create a reconstruction response with the requested trace.
  """
  @spec reconstruction_response(String.t(), VectorClock.t(), Trace.t() | nil) :: message()
  def reconstruction_response(origin, clock, trace) do
    %{
      type: :reconstruction_response,
      origin: origin,
      timestamp: clock,
      trace: trace
    }
  end

  # Encoding/Decoding for Network Transport

  @doc """
  Encode a message to binary format for network transport.
  Uses Erlang's term_to_binary for now; can be replaced with
  more efficient format (protobuf, msgpack, etc.) later.
  """
  @spec encode(message()) :: {:ok, binary()} | {:error, term()}
  def encode(message) do
    try do
      # Convert VectorClock to serializable format
      serializable = message
      |> Map.update(:timestamp, nil, &VectorClock.to_map/1)
      |> maybe_serialize_trace()

      {:ok, :erlang.term_to_binary(serializable, [:compressed])}
    rescue
      e -> {:error, e}
    end
  end

  # Allowlist of valid message type atoms
  @valid_message_types [:ping, :pong, :query, :query_response,
                        :trace_share, :ack, :reconstruction_request,
                        :reconstruction_response]

  @doc """
  Decode a binary message back to a map.

  SECURITY: Uses :safe option to prevent arbitrary code execution,
  and validates message types against an allowlist.
  """
  @spec decode(binary()) :: {:ok, message()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    try do
      decoded = :erlang.binary_to_term(binary, [:safe])

      # Validate message type is in allowlist
      with %{type: type} <- decoded,
           true <- type in @valid_message_types do
        # Reconstruct VectorClock
        message = decoded
        |> Map.update(:timestamp, VectorClock.new(nil), &VectorClock.from_map/1)
        |> maybe_deserialize_trace()

        {:ok, message}
      else
        _ -> {:error, :invalid_message_type}
      end
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Validate a message has required fields.
  """
  @spec valid?(message()) :: boolean()
  def valid?(%{type: type, origin: origin, timestamp: ts})
      when is_atom(type) and is_binary(origin) and is_struct(ts, VectorClock) do
    true
  end
  def valid?(_), do: false

  @doc """
  Get the causal ordering relationship between two messages.
  """
  @spec compare_causality(message(), message()) :: :before | :after | :concurrent | :equal
  def compare_causality(%{timestamp: ts1}, %{timestamp: ts2}) do
    VectorClock.compare(ts1, ts2)
  end

  # Private helpers

  defp maybe_serialize_trace(%{trace: %Trace{} = trace} = msg) do
    Map.put(msg, :trace, trace_to_map(trace))
  end
  defp maybe_serialize_trace(%{traces: traces} = msg) when is_list(traces) do
    Map.put(msg, :traces, Enum.map(traces, &trace_to_map/1))
  end
  defp maybe_serialize_trace(msg), do: msg

  defp maybe_deserialize_trace(%{trace: trace_map} = msg) when is_map(trace_map) and not is_struct(trace_map) do
    Map.put(msg, :trace, map_to_trace(trace_map))
  end
  defp maybe_deserialize_trace(%{traces: traces} = msg) when is_list(traces) do
    Map.put(msg, :traces, Enum.map(traces, fn
      t when is_map(t) and not is_struct(t) -> map_to_trace(t)
      t -> t
    end))
  end
  defp maybe_deserialize_trace(msg), do: msg

  defp trace_to_map(%Trace{} = trace) do
    %{
      id: trace.id,
      origin: trace.origin,
      timestamp: VectorClock.to_map(trace.timestamp),
      purpose: trace.purpose,
      path: trace.path,
      reconstruction_hint: trace.reconstruction_hint
    }
  end

  defp map_to_trace(map) do
    %Trace{
      id: map[:id] || map["id"],
      origin: map[:origin] || map["origin"],
      timestamp: VectorClock.from_map(map[:timestamp] || map["timestamp"] || %{}),
      purpose: map[:purpose] || map["purpose"],
      path: map[:path] || map["path"] || [],
      reconstruction_hint: map[:reconstruction_hint] || map["reconstruction_hint"] || %{}
    }
  end
end
