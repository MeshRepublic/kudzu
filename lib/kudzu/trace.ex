defmodule Kudzu.Trace do
  @moduledoc """
  A Trace is a navigational memory - not a stored fact, but a path to reconstruction.

  Instead of storing "user's birthday is March 15", we store:
  - That something was recorded (origin agent)
  - Why it was recorded (purpose)
  - Where it was placed (path through agent network)
  - How to navigate back (reconstruction_hint)

  The data itself may or may not exist - but the navigation survives.

  ## Phase 2: Content-Addressable Traces

  Traces now use content-addressable IDs (SHA-256 hash of content).
  This enables:
  - Deduplication: Same content = same ID
  - Integrity verification: ID proves content unchanged
  - Efficient synchronization: Only sync by ID comparison

  ## Salience Integration

  Each trace carries a salience score that determines:
  - Priority during recall
  - Consolidation eligibility
  - Archival timing
  """

  alias Kudzu.{VectorClock, Salience}

  @type t :: %__MODULE__{
          id: String.t(),
          origin: String.t(),
          timestamp: VectorClock.t(),
          purpose: atom() | String.t(),
          path: [String.t()],
          reconstruction_hint: map(),
          salience: Salience.t() | nil,
          content_hash: String.t() | nil
        }

  @enforce_keys [:id, :origin, :timestamp, :purpose]
  defstruct [
    :id,
    :origin,
    :timestamp,
    :purpose,
    :salience,
    :content_hash,
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

  ## Options
    - :content_addressable - if true, ID is SHA-256 hash of content (default: true)
    - :importance - salience importance level (:critical, :high, :normal, :low, :trivial)
  """
  @spec new(String.t(), atom() | String.t(), [String.t()] | nil, map(), keyword()) :: t()
  def new(origin, purpose, path \\ nil, reconstruction_hint \\ %{}, opts \\ []) do
    content_addressable = Keyword.get(opts, :content_addressable, true)
    importance = Keyword.get(opts, :importance, :normal)

    # Generate content hash
    content_hash = compute_content_hash(origin, purpose, reconstruction_hint)

    # Use content-addressable ID or random
    id = if content_addressable do
      content_hash
    else
      generate_id()
    end

    # Initialize salience
    salience = Salience.new(importance: importance)

    %__MODULE__{
      id: id,
      origin: origin,
      timestamp: VectorClock.new(origin) |> VectorClock.increment(origin),
      purpose: purpose,
      path: path || [origin],
      reconstruction_hint: reconstruction_hint,
      salience: salience,
      content_hash: content_hash
    }
  end

  @doc """
  Create a trace with an existing vector clock (for receiving traces from peers).
  """
  @spec new_with_clock(String.t(), atom() | String.t(), VectorClock.t(), [String.t()] | nil, map(), keyword()) :: t()
  def new_with_clock(origin, purpose, clock, path \\ nil, reconstruction_hint \\ %{}, opts \\ []) do
    content_addressable = Keyword.get(opts, :content_addressable, true)
    importance = Keyword.get(opts, :importance, :normal)

    content_hash = compute_content_hash(origin, purpose, reconstruction_hint)

    id = if content_addressable do
      content_hash
    else
      generate_id()
    end

    salience = Salience.new(importance: importance)

    %__MODULE__{
      id: id,
      origin: origin,
      timestamp: clock,
      purpose: purpose,
      path: path || [origin],
      reconstruction_hint: reconstruction_hint,
      salience: salience,
      content_hash: content_hash
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

  @doc """
  Update salience when trace is accessed (reconsolidation).
  """
  @spec on_access(t()) :: t()
  def on_access(%__MODULE__{salience: nil} = trace), do: trace
  def on_access(%__MODULE__{salience: salience} = trace) do
    %{trace | salience: Salience.on_access(salience)}
  end

  @doc """
  Update salience after consolidation.
  """
  @spec on_consolidation(t()) :: t()
  def on_consolidation(%__MODULE__{salience: nil} = trace), do: trace
  def on_consolidation(%__MODULE__{salience: salience} = trace) do
    %{trace | salience: Salience.on_consolidation(salience)}
  end

  @doc """
  Get the current salience score.
  """
  @spec salience_score(t()) :: float()
  def salience_score(%__MODULE__{salience: nil}), do: 0.5
  def salience_score(%__MODULE__{salience: salience}), do: Salience.score(salience)

  @doc """
  Verify content integrity using stored hash.
  """
  @spec verify_integrity(t()) :: boolean()
  def verify_integrity(%__MODULE__{content_hash: nil}), do: true
  def verify_integrity(%__MODULE__{} = trace) do
    computed = compute_content_hash(trace.origin, trace.purpose, trace.reconstruction_hint)
    computed == trace.content_hash
  end

  @doc """
  Check if trace is a candidate for consolidation.
  """
  @spec consolidation_candidate?(t(), keyword()) :: boolean()
  def consolidation_candidate?(%__MODULE__{salience: nil}, _opts), do: false
  def consolidation_candidate?(%__MODULE__{salience: salience}, opts) do
    Salience.consolidation_candidate?(salience, opts)
  end

  @doc """
  Check if trace is a candidate for archival.
  """
  @spec archival_candidate?(t(), keyword()) :: boolean()
  def archival_candidate?(%__MODULE__{salience: nil}, _opts), do: false
  def archival_candidate?(%__MODULE__{salience: salience}, opts) do
    Salience.archival_candidate?(salience, opts)
  end

  # Merge paths keeping unique agents in order of first appearance
  defp merge_paths(path1, path2) do
    (path1 ++ path2)
    |> Enum.uniq()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc """
  Compute SHA-256 content hash for content-addressable ID.
  """
  @spec compute_content_hash(String.t(), atom() | String.t(), map()) :: String.t()
  def compute_content_hash(origin, purpose, reconstruction_hint) do
    # Canonical serialization for consistent hashing
    purpose_str = if is_atom(purpose), do: Atom.to_string(purpose), else: purpose

    # Sort hint keys for consistency
    hint_str = reconstruction_hint
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> "#{k}:#{inspect(v)}" end)
    |> Enum.join("|")

    content = "#{origin}|#{purpose_str}|#{hint_str}"

    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
