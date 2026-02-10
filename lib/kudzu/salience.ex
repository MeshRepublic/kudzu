defmodule Kudzu.Salience do
  @moduledoc """
  Salience scoring for memory prioritization.

  Inspired by biological memory systems where emotionally significant
  or frequently accessed memories are consolidated more strongly.

  ## Factors

  - **Novelty**: How unusual or unexpected is this trace?
  - **Recency**: When was this trace last accessed?
  - **Frequency**: How often has this trace been accessed?
  - **Emotional valence**: Importance markers from the creating agent
  - **Associative strength**: How connected is this to other traces?

  ## Decay Model

  Salience decays over time following a power law (like real memory),
  but can be refreshed through reconsolidation on recall.
  """

  @type t :: %__MODULE__{
          novelty: float(),
          recency: DateTime.t(),
          access_count: non_neg_integer(),
          emotional_valence: float(),
          associative_strength: float(),
          importance: atom(),
          created_at: DateTime.t(),
          last_consolidated: DateTime.t() | nil,
          consolidation_count: non_neg_integer()
        }

  defstruct [
    novelty: 0.5,
    recency: nil,
    access_count: 0,
    emotional_valence: 0.0,
    associative_strength: 0.0,
    importance: :normal,
    created_at: nil,
    last_consolidated: nil,
    consolidation_count: 0
  ]

  # Decay parameters (power law)
  @decay_exponent 0.5
  @recency_half_life_hours 24
  @novelty_decay_rate 0.95
  @min_salience 0.01
  @max_salience 1.0

  # Importance multipliers
  @importance_weights %{
    critical: 3.0,
    high: 2.0,
    normal: 1.0,
    low: 0.5,
    trivial: 0.25
  }

  @doc """
  Create a new salience score with initial values.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      novelty: Keyword.get(opts, :novelty, 1.0),  # New traces are maximally novel
      recency: now,
      access_count: 0,
      emotional_valence: Keyword.get(opts, :emotional_valence, 0.0),
      associative_strength: Keyword.get(opts, :associative_strength, 0.0),
      importance: Keyword.get(opts, :importance, :normal),
      created_at: now,
      last_consolidated: nil,
      consolidation_count: 0
    }
  end

  @doc """
  Calculate the current salience score (0.0 to 1.0).

  Combines all factors with their weights, accounting for decay.
  """
  @spec score(t()) :: float()
  def score(%__MODULE__{} = salience) do
    now = DateTime.utc_now()

    # Calculate individual components
    recency_score = recency_factor(salience.recency, now)
    frequency_score = frequency_factor(salience.access_count)
    novelty_score = novelty_factor(salience.novelty, salience.created_at, now)
    emotional_score = emotional_factor(salience.emotional_valence)
    associative_score = salience.associative_strength

    # Weight the importance
    importance_weight = Map.get(@importance_weights, salience.importance, 1.0)

    # Combine factors (weighted geometric mean for more balanced scoring)
    base_score = (
      recency_score * 0.25 +
      frequency_score * 0.20 +
      novelty_score * 0.20 +
      emotional_score * 0.15 +
      associative_score * 0.20
    )

    # Apply importance multiplier and clamp
    final_score = base_score * importance_weight
    clamp(final_score, @min_salience, @max_salience)
  end

  @doc """
  Update salience when a trace is accessed (reconsolidation).
  """
  @spec on_access(t()) :: t()
  def on_access(%__MODULE__{} = salience) do
    %{salience |
      recency: DateTime.utc_now(),
      access_count: salience.access_count + 1,
      # Reconsolidation slightly boosts novelty (memory reconsolidation effect)
      novelty: min(salience.novelty * 1.1, @max_salience)
    }
  end

  @doc """
  Update salience after consolidation.
  """
  @spec on_consolidation(t()) :: t()
  def on_consolidation(%__MODULE__{} = salience) do
    %{salience |
      last_consolidated: DateTime.utc_now(),
      consolidation_count: salience.consolidation_count + 1,
      # Consolidation reduces novelty (memory becomes "settled")
      novelty: salience.novelty * @novelty_decay_rate
    }
  end

  @doc """
  Increase associative strength when trace is linked to others.
  """
  @spec strengthen_associations(t(), float()) :: t()
  def strengthen_associations(%__MODULE__{} = salience, delta \\ 0.1) do
    %{salience |
      associative_strength: clamp(salience.associative_strength + delta, 0.0, @max_salience)
    }
  end

  @doc """
  Set emotional valence (can be positive or negative).
  """
  @spec set_emotional_valence(t(), float()) :: t()
  def set_emotional_valence(%__MODULE__{} = salience, valence) do
    %{salience | emotional_valence: clamp(valence, -1.0, 1.0)}
  end

  @doc """
  Check if this trace is a candidate for consolidation.
  Traces are consolidated when they have high enough salience and
  haven't been consolidated recently.
  """
  @spec consolidation_candidate?(t(), keyword()) :: boolean()
  def consolidation_candidate?(%__MODULE__{} = salience, opts \\ []) do
    min_score = Keyword.get(opts, :min_score, 0.3)
    min_age_hours = Keyword.get(opts, :min_age_hours, 1)
    min_since_consolidation_hours = Keyword.get(opts, :min_since_consolidation_hours, 24)

    now = DateTime.utc_now()
    age_hours = DateTime.diff(now, salience.created_at, :hour)
    current_score = score(salience)

    # Check if old enough
    age_ok = age_hours >= min_age_hours

    # Check if score is high enough
    score_ok = current_score >= min_score

    # Check if not recently consolidated
    consolidation_ok = case salience.last_consolidated do
      nil -> true
      last -> DateTime.diff(now, last, :hour) >= min_since_consolidation_hours
    end

    age_ok and score_ok and consolidation_ok
  end

  @doc """
  Check if this trace is a candidate for archival (move to cold storage).
  """
  @spec archival_candidate?(t(), keyword()) :: boolean()
  def archival_candidate?(%__MODULE__{} = salience, opts \\ []) do
    max_score = Keyword.get(opts, :max_score, 0.2)
    min_age_hours = Keyword.get(opts, :min_age_hours, 24)
    min_consolidations = Keyword.get(opts, :min_consolidations, 1)

    now = DateTime.utc_now()
    age_hours = DateTime.diff(now, salience.created_at, :hour)
    current_score = score(salience)

    # Must be old enough
    age_ok = age_hours >= min_age_hours

    # Score must be low (not actively used)
    score_ok = current_score <= max_score

    # Must have been consolidated at least once (proven value)
    consolidation_ok = salience.consolidation_count >= min_consolidations

    # Critical importance traces are never archived automatically
    importance_ok = salience.importance != :critical

    age_ok and score_ok and consolidation_ok and importance_ok
  end

  @doc """
  Serialize salience to a map for storage.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = salience) do
    %{
      novelty: salience.novelty,
      recency: salience.recency && DateTime.to_iso8601(salience.recency),
      access_count: salience.access_count,
      emotional_valence: salience.emotional_valence,
      associative_strength: salience.associative_strength,
      importance: salience.importance,
      created_at: salience.created_at && DateTime.to_iso8601(salience.created_at),
      last_consolidated: salience.last_consolidated && DateTime.to_iso8601(salience.last_consolidated),
      consolidation_count: salience.consolidation_count
    }
  end

  @doc """
  Deserialize salience from a map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      novelty: Map.get(map, :novelty) || Map.get(map, "novelty", 0.5),
      recency: parse_datetime(Map.get(map, :recency) || Map.get(map, "recency")),
      access_count: Map.get(map, :access_count) || Map.get(map, "access_count", 0),
      emotional_valence: Map.get(map, :emotional_valence) || Map.get(map, "emotional_valence", 0.0),
      associative_strength: Map.get(map, :associative_strength) || Map.get(map, "associative_strength", 0.0),
      importance: parse_importance(Map.get(map, :importance) || Map.get(map, "importance", :normal)),
      created_at: parse_datetime(Map.get(map, :created_at) || Map.get(map, "created_at")),
      last_consolidated: parse_datetime(Map.get(map, :last_consolidated) || Map.get(map, "last_consolidated")),
      consolidation_count: Map.get(map, :consolidation_count) || Map.get(map, "consolidation_count", 0)
    }
  end

  # Private helpers

  defp recency_factor(nil, _now), do: 0.5
  defp recency_factor(recency, now) do
    hours_since = DateTime.diff(now, recency, :second) / 3600.0
    # Power law decay
    :math.pow(0.5, hours_since / @recency_half_life_hours)
  end

  defp frequency_factor(count) do
    # Logarithmic scaling with diminishing returns
    :math.log(count + 1) / :math.log(100)
    |> min(1.0)
  end

  defp novelty_factor(novelty, nil, _now), do: novelty
  defp novelty_factor(novelty, created_at, now) do
    # Novelty decays over time (power law)
    hours_since = DateTime.diff(now, created_at, :second) / 3600.0
    decay = :math.pow(hours_since + 1, -@decay_exponent)
    novelty * decay
    |> max(@min_salience)
  end

  defp emotional_factor(valence) do
    # Absolute emotional intensity matters (both positive and negative)
    abs(valence)
  end

  defp clamp(value, min_val, max_val) do
    value
    |> max(min_val)
    |> min(max_val)
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_importance(atom) when is_atom(atom), do: atom
  defp parse_importance(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      _ -> :normal
    end
  end
end
