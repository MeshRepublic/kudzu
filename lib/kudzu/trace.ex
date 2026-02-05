defmodule Kudzu.Trace do
  @moduledoc """
  A Trace is a navigational memory - not a stored fact, but a path to reconstruction.

  Instead of storing "user's birthday is March 15", we store:
  - That something was recorded (origin agent)
  - Why it was recorded (purpose)
  - Where it was placed (path through agent network)
  - How to navigate back (reconstruction_hint)

  The data itself may or may not exist - but the navigation survives.
  """

  alias Kudzu.VectorClock

  @type t :: %__MODULE__{
          id: String.t(),
          origin: String.t(),
          timestamp: VectorClock.t(),
          purpose: atom() | String.t(),
          path: [String.t()],
          reconstruction_hint: map()
        }

  @enforce_keys [:id, :origin, :timestamp, :purpose]
  defstruct [
    :id,
    :origin,
    :timestamp,
    :purpose,
    path: [],
    reconstruction_hint: %{}
  ]

  @doc """
  Create a new trace.

  ## Parameters
    - origin: agent_id of the creating agent
    - purpose: why this trace was recorded (atom or string)
    - path: initial list of agent_id hops (defaults to [origin])
    - reconstruction_hint: metadata for retrieval (optional)
  """
  @spec new(String.t(), atom() | String.t(), [String.t()], map()) :: t()
  def new(origin, purpose, path \\ nil, reconstruction_hint \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      origin: origin,
      timestamp: VectorClock.new(origin) |> VectorClock.increment(origin),
      purpose: purpose,
      path: path || [origin],
      reconstruction_hint: reconstruction_hint
    }
  end

  @doc """
  Create a trace with an existing vector clock (for receiving traces from peers).
  """
  @spec new_with_clock(String.t(), atom() | String.t(), VectorClock.t(), [String.t()], map()) :: t()
  def new_with_clock(origin, purpose, clock, path \\ nil, reconstruction_hint \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      origin: origin,
      timestamp: clock,
      purpose: purpose,
      path: path || [origin],
      reconstruction_hint: reconstruction_hint
    }
  end

  @doc """
  Follow a trace by adding a hop to the path.
  Returns a new trace with the follower added to the path and clock updated.

  ## Parameters
    - trace: the trace being followed
    - follower_id: agent_id of the agent following the trace
  """
  @spec follow(t(), String.t()) :: t()
  def follow(%__MODULE__{path: path, timestamp: clock} = trace, follower_id) do
    %{trace |
      path: path ++ [follower_id],
      timestamp: clock |> VectorClock.increment(follower_id)
    }
  end

  @doc """
  Merge two traces that share the same origin and purpose.
  Combines paths and takes the later timestamp.
  Useful for reconstructing context from redundant traces.

  Returns {:ok, merged_trace} or {:error, reason}.
  """
  @spec merge(t(), t()) :: {:ok, t()} | {:error, atom()}
  def merge(%__MODULE__{origin: o1, purpose: p1} = t1, %__MODULE__{origin: o2, purpose: p2} = t2)
      when o1 == o2 and p1 == p2 do
    merged_clock = VectorClock.merge(t1.timestamp, t2.timestamp)
    merged_path = merge_paths(t1.path, t2.path)
    merged_hints = Map.merge(t1.reconstruction_hint, t2.reconstruction_hint)

    {:ok, %{t1 |
      timestamp: merged_clock,
      path: merged_path,
      reconstruction_hint: merged_hints
    }}
  end

  def merge(%__MODULE__{}, %__MODULE__{}), do: {:error, :incompatible_traces}

  @doc """
  Check if one trace happened before another (causal ordering).
  """
  @spec happened_before?(t(), t()) :: boolean()
  def happened_before?(%__MODULE__{timestamp: ts1}, %__MODULE__{timestamp: ts2}) do
    VectorClock.happened_before?(ts1, ts2)
  end

  @doc """
  Get the length of the trace path (number of hops).
  """
  @spec path_length(t()) :: non_neg_integer()
  def path_length(%__MODULE__{path: path}), do: length(path)

  @doc """
  Check if an agent appears in the trace path.
  """
  @spec visited?(t(), String.t()) :: boolean()
  def visited?(%__MODULE__{path: path}, agent_id), do: agent_id in path

  @doc """
  Get the last agent in the path.
  """
  @spec current_location(t()) :: String.t() | nil
  def current_location(%__MODULE__{path: []}), do: nil
  def current_location(%__MODULE__{path: path}), do: List.last(path)

  @doc """
  Add reconstruction metadata.
  """
  @spec add_hint(t(), atom() | String.t(), term()) :: t()
  def add_hint(%__MODULE__{reconstruction_hint: hints} = trace, key, value) do
    %{trace | reconstruction_hint: Map.put(hints, key, value)}
  end

  # Merge paths keeping unique agents in order of first appearance
  defp merge_paths(path1, path2) do
    (path1 ++ path2)
    |> Enum.uniq()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
