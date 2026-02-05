defmodule Kudzu.VectorClock do
  @moduledoc """
  Vector clock implementation for causal ordering of events.

  Each agent maintains its own counter. When agents communicate,
  clocks are merged to establish happened-before relationships.
  """

  @type t :: %__MODULE__{
          clocks: %{String.t() => non_neg_integer()}
        }

  defstruct clocks: %{}

  @doc """
  Create a new vector clock, optionally initialized for an agent.
  """
  @spec new(String.t() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(agent_id) when is_binary(agent_id) do
    %__MODULE__{clocks: %{agent_id => 0}}
  end

  @doc """
  Increment the clock for a specific agent (typically self).
  """
  @spec increment(t(), String.t()) :: t()
  def increment(%__MODULE__{clocks: clocks} = vc, agent_id) do
    new_count = Map.get(clocks, agent_id, 0) + 1
    %{vc | clocks: Map.put(clocks, agent_id, new_count)}
  end

  @doc """
  Merge two vector clocks, taking the maximum of each component.
  Used when receiving a message to update local clock.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{clocks: c1}, %__MODULE__{clocks: c2}) do
    merged = Map.merge(c1, c2, fn _k, v1, v2 -> max(v1, v2) end)
    %__MODULE__{clocks: merged}
  end

  @doc """
  Compare two vector clocks.
  Returns:
    :before  - vc1 happened before vc2
    :after   - vc1 happened after vc2
    :concurrent - neither happened before the other
    :equal   - identical clocks
  """
  @spec compare(t(), t()) :: :before | :after | :concurrent | :equal
  def compare(%__MODULE__{clocks: c1}, %__MODULE__{clocks: c2}) do
    all_keys = MapSet.union(MapSet.new(Map.keys(c1)), MapSet.new(Map.keys(c2)))

    {less, greater} = Enum.reduce(all_keys, {false, false}, fn key, {less_acc, greater_acc} ->
      v1 = Map.get(c1, key, 0)
      v2 = Map.get(c2, key, 0)

      cond do
        v1 < v2 -> {true, greater_acc}
        v1 > v2 -> {less_acc, true}
        true -> {less_acc, greater_acc}
      end
    end)

    case {less, greater} do
      {false, false} -> :equal
      {true, false} -> :before
      {false, true} -> :after
      {true, true} -> :concurrent
    end
  end

  @doc """
  Check if vc1 happened before vc2.
  """
  @spec happened_before?(t(), t()) :: boolean()
  def happened_before?(vc1, vc2), do: compare(vc1, vc2) == :before

  @doc """
  Get the clock value for a specific agent.
  """
  @spec get(t(), String.t()) :: non_neg_integer()
  def get(%__MODULE__{clocks: clocks}, agent_id) do
    Map.get(clocks, agent_id, 0)
  end

  @doc """
  Convert to a map for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{clocks: clocks}), do: clocks

  @doc """
  Create from a map (deserialization).
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{clocks: map}
  end
end
