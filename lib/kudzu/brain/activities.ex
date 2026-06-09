defmodule Kudzu.Brain.Activities do
  @moduledoc """
  Always-awake activity loop for `Kudzu.Brain`.

  Owns the periodic activity tick (`:activity_cycle`) — health check,
  distillation, storage check, web learning, curiosity — plus the
  hologram-anomaly pre-check gate and the kudzu_brain hologram bootstrap.

  Sub-modules are fire-and-forget within each activity: long-running
  work is dispatched as `Task.start/1` so it cannot block the Brain
  GenServer.
  """

  require Logger

  alias Kudzu.Brain
  alias Kudzu.Brain.ActivityIndicator
  alias Kudzu.Brain.Curiosity
  alias Kudzu.Brain.Distiller
  alias Kudzu.Brain.LearningGoal
  alias Kudzu.Brain.Reasoning
  alias Kudzu.Brain.Thought
  alias Kudzu.Brain.Vectors.Router, as: VectorRouter
  alias Kudzu.Brain.WorkingMemory

  # Activity loop intervals (always-awake mode)
  # Check for overdue activities every 10s
  @activity_tick 10_000
  # Health checks: every 1 minute
  @health_interval 60_000
  # Curiosity exploration: every 2 minutes
  @curiosity_interval 120_000
  # Web research: every 5 minutes
  @web_learning_interval 300_000
  # Knowledge distillation: every 10 minutes
  @distillation_interval 600_000
  # Storage monitoring: every 30 minutes
  @storage_interval 1_800_000

  @consolidation_staleness_ms 1_200_000

  @doc """
  Run the most-overdue activity once, dispatching to the appropriate
  handler (health / distillation / storage / web-learning / curiosity)
  and decaying working memory.

  Returns the (possibly updated) Brain state. Activity body runs under
  `Process.flag(:trap_exit, true)` so a crashed `Task.start` cannot
  bring down the Brain GenServer. The next tick is **not** scheduled
  here — callers schedule via `schedule_next/0`.
  """
  @spec run_cycle(Brain.t()) :: Brain.t()
  def run_cycle(state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | status: :active}

    # Run the most overdue activity (wrapped in trap_exit + try/catch for resilience)
    # Trap exits temporarily so linked Task.async crashes don't kill the Brain
    old_trap = Process.flag(:trap_exit, true)

    state =
      try do
        cond do
          overdue?(state.last_health_check, @health_interval, now) ->
            Logger.debug("[Brain] Activity: health check")
            ActivityIndicator.start_activity(:health_check, "health check")
            result = run_health_check(%{state | last_health_check: now})
            ActivityIndicator.stop_activity(:health_check)
            result

          overdue?(state.last_distillation, @distillation_interval, now) ->
            Logger.debug("[Brain] Activity: distillation")
            ActivityIndicator.start_activity(:distilling, "distilling knowledge")
            result = run_distillation_cycle(%{state | last_distillation: now})
            ActivityIndicator.stop_activity(:distilling)
            result

          overdue?(state.last_storage_check, @storage_interval, now) ->
            Logger.debug("[Brain] Activity: storage check")
            ActivityIndicator.start_activity(:storage, "checking storage")
            result = run_storage_check(%{state | last_storage_check: now})
            ActivityIndicator.stop_activity(:storage)
            result

          overdue?(state.last_web_learning, @web_learning_interval, now) and
              not state.web_learning_active ->
            Logger.debug("[Brain] Activity: web learning")
            run_web_learning(%{state | last_web_learning: now, web_learning_active: true})

          overdue?(state.last_curiosity, @curiosity_interval, now) ->
            Logger.debug("[Brain] Activity: curiosity")
            run_curiosity(%{state | last_curiosity: now})

          true ->
            # Nothing overdue — idle tick
            state
        end
      catch
        kind, reason ->
          Logger.warning("[Brain] Activity crashed: #{inspect(kind)}: #{inspect(reason)}")
          # Return unchanged state on crash
          state
      after
        Process.flag(:trap_exit, old_trap)
        # Flush any trapped EXIT messages so they don't pile up
        receive do
          {:EXIT, _pid, _reason} -> :ok
        after
          0 -> :ok
        end
      end

    # Decay working memory periodically
    if state.working_memory do
      %{state | working_memory: WorkingMemory.decay(state.working_memory, 0.01)}
    else
      state
    end
  end

  @doc """
  Schedule the next `:activity_cycle` message at the standard tick
  interval. Expects to be called from within the Brain GenServer
  process so `self()` resolves to the Brain pid.
  """
  @spec schedule_next() :: reference()
  def schedule_next do
    Process.send_after(self(), :activity_cycle, @activity_tick)
  end

  @doc """
  Find or spawn the `kudzu_brain` hologram with the given desires.

  Returns `{:ok, pid, id}` on success. Exceptions from the hologram
  subsystem are caught and returned as `{:error, {:exception, _}}` so
  the Brain can retry on its own schedule.
  """
  @spec init_hologram([String.t()]) :: {:ok, pid(), String.t()} | {:error, term()}
  def init_hologram(desires) do
    case Kudzu.Application.find_by_purpose("kudzu_brain") do
      [{pid, id} | _] ->
        Logger.info("[Brain] Found existing kudzu_brain hologram: #{id}")
        {:ok, pid, id}

      [] ->
        Logger.info("[Brain] Spawning new kudzu_brain hologram")

        case Kudzu.Application.spawn_hologram(
               purpose: "kudzu_brain",
               desires: desires,
               cognition: false,
               constitution: :kudzu_evolve
             ) do
          {:ok, pid} ->
            id = Kudzu.Hologram.get_id(pid)
            {:ok, pid, id}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Promote the first queued learning goal to `:active` if no goal is
  currently active. Returns the (possibly updated) goal list. Pure
  function over the list — does not touch state or persistence.
  """
  @spec maybe_activate_next_goal([struct()]) :: [struct()]
  def maybe_activate_next_goal(goals) do
    has_active = Enum.any?(goals, &(&1.status == :active))

    if has_active do
      goals
    else
      case Enum.find_index(goals, &(&1.status == :queued)) do
        nil ->
          goals

        idx ->
          List.update_at(goals, idx, &%{&1 | status: :active})
      end
    end
  end

  # ── Activity Handlers ────────────────────────────────────────────

  defp run_health_check(state) do
    new_count = state.cycle_count + 1
    state = %{state | cycle_count: new_count}

    case pre_check(state) do
      :sleep ->
        state

      {:wake, anomalies} ->
        Logger.info("[Brain] Health check: #{length(anomalies)} anomalies")
        Reasoning.reason(state, anomalies)
    end
  end

  defp run_curiosity(state) do
    # Run curiosity asynchronously to avoid blocking the Brain
    brain_pid = self()
    hologram_pid = state.hologram_pid
    desires = state.desires
    wm = state.working_memory || WorkingMemory.new()
    silo_domains = get_silo_domains_for_activity()

    Task.start(fn ->
      try do
        questions = Curiosity.generate(desires, wm, silo_domains)

        if question = List.first(questions) do
          thought_result =
            Thought.run(question,
              monarch_pid: brain_pid,
              timeout: 8_000,
              priming: []
            )

          if hologram_pid do
            Kudzu.Hologram.record_trace(hologram_pid, :thought, %{
              source: "curiosity",
              question: question,
              resolution: thought_result.resolution,
              confidence: thought_result.confidence
            })
          end
        end
      catch
        kind, reason ->
          Logger.warning("[Brain] Async curiosity crashed: #{inspect(kind)}: #{inspect(reason)}")
      end
    end)

    state
  end

  defp run_web_learning(state) do
    # Priority: active learning goal topics over curiosity questions
    case get_learning_topic(state) do
      {:learning, topic, goal_id, topic_index} ->
        Logger.info("[Brain] Web learning: curriculum topic '#{topic}' (goal=#{goal_id})")
        brain_pid = self()
        hologram_pid = state.hologram_pid

        Task.start(fn ->
          ActivityIndicator.start_activity(:learning, "learning: #{String.slice(topic, 0, 50)}")

          try do
            result = VectorRouter.learn(topic)

            case result do
              {:ok, findings} ->
                vector_name = Map.get(findings, :vector, "unknown")
                ActivityIndicator.stop_activity(:learning)

                if hologram_pid do
                  Kudzu.Hologram.record_trace(hologram_pid, :learning, %{
                    source: "directed_learning",
                    goal_id: goal_id,
                    topic: topic,
                    vector: vector_name,
                    content_preview: findings.content |> String.slice(0, 200)
                  })
                end

                send(brain_pid, {:learning_progress, goal_id, topic_index, :complete})
                send(brain_pid, :web_learning_done)

              {:error, reason} ->
                ActivityIndicator.stop_activity(:learning)
                Logger.warning("[Brain] Learning topic failed: #{topic} — #{inspect(reason)}")
                send(brain_pid, {:learning_progress, goal_id, topic_index, :failed})
                send(brain_pid, :web_learning_done)
            end
          catch
            kind, reason ->
              ActivityIndicator.stop_activity(:learning)

              Logger.warning(
                "[Brain] Learning topic crashed: #{inspect(kind)}: #{inspect(reason)}"
              )

              send(brain_pid, {:learning_progress, goal_id, topic_index, :failed})
          end
        end)

        state

      :no_learning_topic ->
        # Fall back to curiosity-driven web learning (existing behavior)
        run_curiosity_web_learning(state)
    end
  end

  defp get_learning_topic(state) do
    case Enum.find(state.learning_goals, &(&1.status == :active)) do
      %LearningGoal{id: goal_id} = goal ->
        case LearningGoal.next_topic(goal) do
          {topic, index} -> {:learning, topic, goal_id, index}
          nil -> :no_learning_topic
        end

      nil ->
        :no_learning_topic
    end
  end

  defp run_curiosity_web_learning(state) do
    # Generate a curiosity question, then research it on the web
    # Run asynchronously so we don't block the Brain GenServer
    silo_domains = get_silo_domains_for_activity()
    wm = state.working_memory || WorkingMemory.new()
    questions = Curiosity.generate(state.desires, wm, silo_domains)

    # Filter out already-researched topics
    question =
      questions
      |> Enum.reject(fn q ->
        normalized = q |> String.downcase() |> String.replace(~r/[^\w\s]/, "") |> String.trim()
        MapSet.member?(state.researched_topics, normalized)
      end)
      |> List.first()

    if question do
      brain_pid = self()
      hologram_pid = state.hologram_pid

      # Fire-and-forget: run web learning in a separate unlinked process
      Task.start(fn ->
        ActivityIndicator.start_activity(
          :curiosity_learn,
          "curious: #{String.slice(question, 0, 50)}"
        )

        try do
          # First try Thought
          thought_result =
            Thought.run(question,
              monarch_pid: brain_pid,
              timeout: 8_000,
              priming: []
            )

          if thought_result.resolution in [:no_match, :partial] do
            # Thought didn't know — research via vectors
            case VectorRouter.learn(question) do
              {:ok, result} ->
                ActivityIndicator.stop_activity(:curiosity_learn)
                # Record trace directly on the hologram
                if hologram_pid do
                  Kudzu.Hologram.record_trace(hologram_pid, :discovery, %{
                    source: "vector_learning",
                    question: question,
                    vector: Map.get(result, :vector, "unknown"),
                    content_preview: result.content |> String.slice(0, 200)
                  })
                end

                # Notify brain to track as researched
                send(brain_pid, {:web_learning_complete, question})

              {:error, reason} ->
                ActivityIndicator.stop_activity(:curiosity_learn)
                Logger.warning("[Brain] Vector learning failed: #{inspect(reason)}")
            end
          else
            ActivityIndicator.stop_activity(:curiosity_learn)
            Logger.debug("[Brain] Web learning skipped — Thought resolved: #{question}")
          end
        catch
          kind, reason ->
            ActivityIndicator.stop_activity(:curiosity_learn)

            Logger.warning(
              "[Brain] Async web learning crashed: #{inspect(kind)}: #{inspect(reason)}"
            )
        end
      end)

      state
    else
      state
    end
  end

  defp run_distillation_cycle(state) do
    Logger.info("[Brain] Running distillation cycle (Phase 3)")

    try do
      result = Distiller.review_knowledge()

      Brain.record_trace(state, :observation, %{
        source: "distillation_cycle",
        action: "knowledge_review",
        reviewed: result.reviewed,
        merged: result.merged,
        pruned: result.pruned
      })

      Logger.info(
        "[Brain] Distillation complete: " <>
          "#{result.reviewed} reviewed, #{result.merged} merged, #{result.pruned} pruned"
      )
    rescue
      e ->
        Logger.warning("[Brain] Distillation cycle failed: #{inspect(e)}")
    catch
      kind, reason ->
        Logger.warning("[Brain] Distillation cycle crashed: #{inspect(kind)}: #{inspect(reason)}")
    end

    state
  end

  defp run_storage_check(state) do
    try do
      stats = Kudzu.Storage.detailed_stats()

      Logger.info(
        "[Brain] Storage: hot=#{stats.hot_count} entries (#{div(stats.hot_bytes, 1024)}KB), " <>
          "warm=#{div(stats.warm_bytes, 1024)}KB, " <>
          "total=#{div(stats.total_bytes, 1_048_576)}MB, " <>
          "utilization=#{stats.utilization}%"
      )

      # Embed unembedded traces (batch of 3 per cycle)
      embedded =
        try do
          Kudzu.Storage.embed_batch(3)
        catch
          _, _ -> 0
        end

      if embedded > 0 do
        Logger.debug("[Brain] Embedded #{embedded} traces")
      end

      # Evict if utilization exceeds 80%
      evicted =
        if stats.utilization > 80.0 do
          count = Kudzu.Storage.evict_lowest(100)

          Logger.warning(
            "[Brain] Storage utilization #{stats.utilization}% > 80% — evicted #{count} traces"
          )

          count
        else
          0
        end

      # Record metrics as a trace
      Brain.record_trace(state, :observation, %{
        type: "storage_check",
        hot_count: stats.hot_count,
        hot_bytes: stats.hot_bytes,
        warm_bytes: stats.warm_bytes,
        total_bytes: stats.total_bytes,
        utilization: stats.utilization,
        evicted: evicted
      })

      state
    catch
      kind, reason ->
        Logger.warning("[Brain] Storage check failed: #{inspect(kind)}: #{inspect(reason)}")
        state
    end
  end

  defp get_silo_domains_for_activity do
    try do
      Kudzu.Silo.list()
      |> Enum.map(fn {domain, _, _} -> domain end)
      |> Enum.reject(&(&1 == nil))
    catch
      _, _ -> []
    end
  end

  defp overdue?(nil, _interval, _now), do: true

  defp overdue?(last, interval, now) do
    now - last >= interval
  end

  # ── Pre-Check Gate ──────────────────────────────────────────────────

  defp pre_check(_state) do
    checks = [
      check_consolidation_recency(),
      check_hologram_count(),
      check_storage_health()
    ]

    anomalies =
      checks
      |> Enum.filter(fn
        {:anomaly, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:anomaly, detail} -> detail end)

    case anomalies do
      [] -> :sleep
      list -> {:wake, list}
    end
  end

  defp check_consolidation_recency do
    stats = Kudzu.Consolidation.stats()
    last = Map.get(stats, :last_consolidation)

    cond do
      is_nil(last) ->
        {:anomaly, %{check: :consolidation_recency, reason: "No consolidation has ever run"}}

      is_struct(last, DateTime) ->
        age_ms = DateTime.diff(DateTime.utc_now(), last, :millisecond)

        if age_ms > @consolidation_staleness_ms do
          {:anomaly,
           %{
             check: :consolidation_recency,
             reason:
               "Last consolidation was #{div(age_ms, 1_000)}s ago " <>
                 "(threshold: #{div(@consolidation_staleness_ms, 1_000)}s)",
             age_ms: age_ms
           }}
        else
          {:nominal, :consolidation_recency}
        end

      true ->
        # last_consolidation is a non-nil, non-DateTime value — treat as nominal
        # (could be a monotonic timestamp or other internal representation)
        {:nominal, :consolidation_recency}
    end
  rescue
    e ->
      {:anomaly,
       %{
         check: :consolidation_recency,
         reason: "Consolidation stats failed: #{Exception.message(e)}"
       }}
  end

  defp check_hologram_count do
    count = Kudzu.Application.hologram_count()

    if count >= 1 do
      {:nominal, :hologram_count}
    else
      {:anomaly,
       %{
         check: :hologram_count,
         reason: "No active holograms (count: #{count})",
         count: count
       }}
    end
  rescue
    e ->
      {:anomaly,
       %{
         check: :hologram_count,
         reason: "Hologram count check failed: #{Exception.message(e)}"
       }}
  end

  defp check_storage_health do
    # Query for any observation traces with limit 1 as a liveness check.
    # We don't care about the result — only that Storage responds without crashing.
    _result = Kudzu.Storage.query(:observation, limit: 1)
    {:nominal, :storage_health}
  rescue
    e ->
      {:anomaly,
       %{
         check: :storage_health,
         reason: "Storage query failed: #{Exception.message(e)}"
       }}
  end
end
