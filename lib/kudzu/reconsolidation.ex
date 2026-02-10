defmodule Kudzu.Reconsolidation do
  @moduledoc """
  Memory reconsolidation - the process by which memories are modified during recall.

  When a memory is recalled, it enters a labile state where it can be:
  - Strengthened (increased salience)
  - Updated (new associations)
  - Modified (context integration)
  - Weakened (if recall context differs significantly)

  This mirrors biological memory reconsolidation where recalled memories
  must be "re-stored" and can be altered in the process.

  ## Why Reconsolidation Matters for AI Memory

  1. **Adaptive memory**: Memories evolve with new context
  2. **Relevance maintenance**: Frequently recalled = more refined
  3. **Context sensitivity**: Same memory adapts to different uses
  4. **Forgetting mechanism**: Unused memories naturally decay

  ## Process

  1. Recall triggers reconsolidation window
  2. Current context is captured
  3. Trace is updated with new associations
  4. Salience is recalculated
  5. Trace is re-stored with modifications
  """

  alias Kudzu.{Trace, Salience, Storage}

  require Logger

  @doc """
  Reconsolidate a trace after recall.

  Updates the trace with new context and recalculates salience.
  Returns the modified trace.
  """
  @spec reconsolidate(Trace.t(), map()) :: Trace.t()
  def reconsolidate(%Trace{} = trace, context \\ %{}) do
    # Step 1: Mark trace as accessed (salience boost)
    trace = Trace.on_access(trace)

    # Step 2: Integrate new context into reconstruction hint
    trace = integrate_context(trace, context)

    # Step 3: Update associations if context provides related traces
    trace = update_associations(trace, context)

    # Step 4: Verify integrity hasn't been compromised
    if Trace.verify_integrity(trace) do
      trace
    else
      Logger.warning("[Reconsolidation] Trace integrity check failed for #{trace.id}")
      trace
    end
  end

  @doc """
  Reconsolidate a trace and persist the changes.
  """
  @spec reconsolidate_and_persist(Trace.t(), String.t(), map()) :: {:ok, Trace.t()} | {:error, term()}
  def reconsolidate_and_persist(%Trace{} = trace, hologram_id, context \\ %{}) do
    reconsolidated = reconsolidate(trace, context)

    # Persist to storage
    importance = case reconsolidated.salience do
      %Salience{importance: imp} -> imp
      _ -> :normal
    end

    case Storage.store(reconsolidated, hologram_id, importance) do
      :ok -> {:ok, reconsolidated}
      error -> error
    end
  end

  @doc """
  Batch reconsolidation for multiple related traces.
  This is more efficient and allows cross-trace association building.
  """
  @spec reconsolidate_batch([Trace.t()], map()) :: [Trace.t()]
  def reconsolidate_batch(traces, context \\ %{}) do
    # Build association map from the batch
    association_context = build_batch_associations(traces)

    # Reconsolidate each with shared context
    combined_context = Map.merge(context, association_context)

    Enum.map(traces, fn trace ->
      reconsolidate(trace, combined_context)
    end)
  end

  @doc """
  Calculate memory "stability" - how resistant to modification.

  Highly consolidated, frequently accessed memories are more stable.
  """
  @spec stability(Trace.t()) :: float()
  def stability(%Trace{salience: nil}), do: 0.5
  def stability(%Trace{salience: salience}) do
    # Stability increases with:
    # - More consolidations
    # - Lower novelty (memory has "settled")
    # - Higher importance

    consolidation_factor = min(salience.consolidation_count / 10.0, 1.0)
    novelty_factor = 1.0 - salience.novelty
    importance_factor = case salience.importance do
      :critical -> 1.0
      :high -> 0.8
      :normal -> 0.5
      :low -> 0.3
      :trivial -> 0.1
    end

    (consolidation_factor * 0.4 + novelty_factor * 0.3 + importance_factor * 0.3)
    |> max(0.0)
    |> min(1.0)
  end

  @doc """
  Determine if a trace should be modified during reconsolidation.

  Low stability = more malleable during recall.
  """
  @spec should_modify?(Trace.t(), map()) :: boolean()
  def should_modify?(%Trace{} = trace, context) do
    stab = stability(trace)
    context_strength = Map.get(context, :strength, 0.5)

    # Lower stability = higher chance of modification
    # Stronger context = higher chance of modification
    modification_threshold = stab * (1.0 - context_strength * 0.5)

    :rand.uniform() > modification_threshold
  end

  @doc """
  Apply context-dependent modification to a trace.

  This is the core reconsolidation mechanism where memories
  are updated based on the recall context.
  """
  @spec apply_modification(Trace.t(), atom(), term()) :: Trace.t()
  def apply_modification(%Trace{} = trace, :strengthen_association, related_purpose) do
    # Add or strengthen association to related purpose
    current_associations = Map.get(trace.reconstruction_hint, :associations, [])
    updated_associations = [related_purpose | current_associations] |> Enum.uniq() |> Enum.take(10)

    %{trace |
      reconstruction_hint: Map.put(trace.reconstruction_hint, :associations, updated_associations),
      salience: strengthen_salience_associations(trace.salience)
    }
  end

  def apply_modification(%Trace{} = trace, :add_context, new_context) when is_map(new_context) do
    # Merge new context into reconstruction hint
    current_context = Map.get(trace.reconstruction_hint, :context, %{})
    merged_context = Map.merge(current_context, new_context)

    %{trace |
      reconstruction_hint: Map.put(trace.reconstruction_hint, :context, merged_context)
    }
  end

  def apply_modification(%Trace{} = trace, :update_emotional_valence, valence) when is_number(valence) do
    case trace.salience do
      nil ->
        trace
      salience ->
        %{trace | salience: Salience.set_emotional_valence(salience, valence)}
    end
  end

  def apply_modification(trace, _type, _value), do: trace

  # Private functions

  defp integrate_context(%Trace{} = trace, context) when map_size(context) == 0, do: trace
  defp integrate_context(%Trace{} = trace, context) do
    # Only integrate if context has relevant keys
    relevant_keys = [:recall_purpose, :recall_query, :related_traces]

    integrable = context
    |> Map.take(relevant_keys)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()

    if map_size(integrable) > 0 do
      current_recall_history = Map.get(trace.reconstruction_hint, :recall_history, [])
      new_recall = %{
        at: DateTime.utc_now(),
        context: integrable
      }
      # Keep last 5 recall events
      updated_history = [new_recall | current_recall_history] |> Enum.take(5)

      %{trace |
        reconstruction_hint: Map.put(trace.reconstruction_hint, :recall_history, updated_history)
      }
    else
      trace
    end
  end

  defp update_associations(%Trace{} = trace, context) do
    case Map.get(context, :related_traces) do
      nil ->
        trace

      related when is_list(related) ->
        # Extract purposes from related traces
        related_purposes = related
        |> Enum.map(fn
          %Trace{purpose: p} -> p
          %{purpose: p} -> p
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

        if related_purposes != [] do
          current_associations = Map.get(trace.reconstruction_hint, :associations, [])
          updated = (current_associations ++ related_purposes) |> Enum.uniq() |> Enum.take(10)

          new_hint = Map.put(trace.reconstruction_hint, :associations, updated)
          new_salience = strengthen_salience_associations(trace.salience)

          %{trace | reconstruction_hint: new_hint, salience: new_salience}
        else
          trace
        end

      _ ->
        trace
    end
  end

  defp build_batch_associations(traces) do
    # Build a map of purposes -> traces for cross-linking
    by_purpose = Enum.group_by(traces, & &1.purpose)

    %{
      batch_purposes: Map.keys(by_purpose),
      related_traces: traces
    }
  end

  defp strengthen_salience_associations(nil), do: nil
  defp strengthen_salience_associations(%Salience{} = salience) do
    Salience.strengthen_associations(salience, 0.05)
  end
end
