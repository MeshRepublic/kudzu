#!/usr/bin/env python3
"""Patch brain.ex for always-awake activity loop (Phase 2)."""

import sys

brain_path = sys.argv[1] if len(sys.argv) > 1 else "lib/kudzu/brain/brain.ex"

with open(brain_path, "r") as f:
    content = f.read()

# 1. Add activity interval constants after existing constants
old_constants = "  @default_cycle_interval 300_000\n  @init_delay 2_000\n  @retry_delay 10_000\n  @consolidation_staleness_ms 1_200_000"

new_constants = """  @default_cycle_interval 300_000
  @init_delay 2_000
  @retry_delay 10_000
  @consolidation_staleness_ms 1_200_000

  # Activity loop intervals (always-awake mode)
  @activity_tick 10_000          # Check for overdue activities every 10s
  @health_interval 60_000        # Health checks: every 1 minute
  @curiosity_interval 120_000    # Curiosity exploration: every 2 minutes
  @web_learning_interval 300_000 # Web research: every 5 minutes
  @distillation_interval 600_000 # Knowledge distillation: every 10 minutes
  @storage_interval 1_800_000    # Storage monitoring: every 30 minutes"""

content = content.replace(old_constants, new_constants)

# 2. Replace struct with new state fields
old_struct = """  defstruct [
    :hologram_id,
    :hologram_pid,
    :current_session,
    :budget,
    :working_memory,
    desires: @initial_desires,
    status: :sleeping,
    cycle_interval: @default_cycle_interval,
    cycle_count: 0,
    config: %{}
  ]"""

new_struct = """  defstruct [
    :hologram_id,
    :hologram_pid,
    :current_session,
    :budget,
    :working_memory,
    desires: @initial_desires,
    status: :active,
    cycle_interval: @default_cycle_interval,
    cycle_count: 0,
    config: %{},
    # Activity tracking (always-awake mode)
    last_health_check: 0,
    last_curiosity: 0,
    last_web_learning: 0,
    last_distillation: 0,
    last_storage_check: 0,
    researched_topics: MapSet.new()
  ]"""

content = content.replace(old_struct, new_struct)

# 3. Replace the two wake_cycle handlers
old_wake_nil = """  def handle_info(:wake_cycle, %{hologram_id: nil} = state) do
    Logger.debug("[Brain] Skipping wake cycle — no hologram attached")
    schedule_wake_cycle(state.cycle_interval)
    {:noreply, state}
  end"""

old_wake_main = """  def handle_info(:wake_cycle, state) do
    new_count = state.cycle_count + 1
    Logger.debug("[Brain] Wake cycle #\#{new_count}")

    state = %{state | cycle_count: new_count, status: :reasoning}

    state = case pre_check(state) do
      :sleep ->
        Logger.debug("[Brain] Pre-check nominal — exploring curiosity")
        # No anomalies — pursue curiosity instead
        maybe_explore_curiosity(state)

      {:wake, anomalies} ->
        Logger.info("[Brain] Cycle \#{new_count}: \#{length(anomalies)} anomalies")
        reason(state, anomalies)
    end

    # Decay working memory at end of each cycle
    state = if state.working_memory do
      %{state | working_memory: WorkingMemory.decay(state.working_memory, 0.05)}
    else
      state
    end

    schedule_wake_cycle(state.cycle_interval)
    {:noreply, %{state | status: :sleeping}}
  end"""

new_wake = """  # Backward compatibility: :wake_cycle forwards to :activity_cycle
  def handle_info(:wake_cycle, state) do
    send(self(), :activity_cycle)
    {:noreply, state}
  end

  def handle_info(:activity_cycle, %{hologram_id: nil} = state) do
    Logger.debug("[Brain] Skipping activity cycle — no hologram attached")
    schedule_activity_cycle()
    {:noreply, state}
  end

  def handle_info(:activity_cycle, state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | status: :active}

    # Run the most overdue activity
    state =
      cond do
        overdue?(state.last_health_check, @health_interval, now) ->
          Logger.debug("[Brain] Activity: health check")
          run_health_check(%{state | last_health_check: now})

        overdue?(state.last_distillation, @distillation_interval, now) ->
          Logger.debug("[Brain] Activity: distillation")
          run_distillation_cycle(%{state | last_distillation: now})

        overdue?(state.last_storage_check, @storage_interval, now) ->
          Logger.debug("[Brain] Activity: storage check")
          run_storage_check(%{state | last_storage_check: now})

        overdue?(state.last_web_learning, @web_learning_interval, now) ->
          Logger.debug("[Brain] Activity: web learning")
          run_web_learning(%{state | last_web_learning: now})

        overdue?(state.last_curiosity, @curiosity_interval, now) ->
          Logger.debug("[Brain] Activity: curiosity")
          run_curiosity(%{state | last_curiosity: now})

        true ->
          state  # Nothing overdue — idle tick
      end

    # Decay working memory periodically
    state = if state.working_memory do
      %{state | working_memory: WorkingMemory.decay(state.working_memory, 0.01)}
    else
      state
    end

    schedule_activity_cycle()
    {:noreply, state}
  end"""

# Remove the nil handler first, then replace the main handler
content = content.replace(old_wake_nil + "\n\n" + old_wake_main, new_wake)

# 4. Add schedule_activity_cycle and activity handlers after schedule_wake_cycle
old_schedule = """  defp schedule_wake_cycle(interval) do
    Process.send_after(self(), :wake_cycle, interval)
  end
end"""

new_schedule = """  defp schedule_wake_cycle(interval) do
    Process.send_after(self(), :wake_cycle, interval)
  end

  defp schedule_activity_cycle do
    Process.send_after(self(), :activity_cycle, @activity_tick)
  end

  defp overdue?(last, interval, now) do
    (now - last) >= interval
  end

  # ── Activity Handlers ────────────────────────────────────────────

  defp run_health_check(state) do
    new_count = state.cycle_count + 1
    state = %{state | cycle_count: new_count}

    case pre_check(state) do
      :sleep ->
        state

      {:wake, anomalies} ->
        Logger.info("[Brain] Health check: \#{length(anomalies)} anomalies")
        reason(state, anomalies)
    end
  end

  defp run_curiosity(state) do
    maybe_explore_curiosity(state)
  end

  defp run_web_learning(state) do
    # Generate a curiosity question, then research it on the web
    silo_domains = get_silo_domains_for_activity()
    wm = state.working_memory || WorkingMemory.new()
    questions = Curiosity.generate(state.desires, wm, silo_domains)

    # Filter out already-researched topics
    question =
      questions
      |> Enum.reject(fn q ->
        normalized = q |> String.downcase() |> String.replace(~r/[^\\w\\s]/, "") |> String.trim()
        MapSet.member?(state.researched_topics, normalized)
      end)
      |> List.first()

    if question do
      # First try Thought — if it already knows, skip web
      priming = if state.working_memory do
        WorkingMemory.get_priming_concepts(state.working_memory, 3)
      else
        []
      end

      thought_result = Thought.run(question,
        monarch_pid: self(),
        timeout: 8_000,
        priming: priming
      )

      state = integrate_thought(state, thought_result)

      if thought_result.resolution in [:no_match, :partial] do
        # Thought didn't know — research on the web
        case WebLearner.research(question) do
          {:ok, result} ->
            record_trace(state, :discovery, %{
              source: "web_learning",
              question: question,
              pages_read: result.pages_read,
              chains_stored: result.chains_stored
            })

            # Track as researched
            normalized = question |> String.downcase() |> String.replace(~r/[^\\w\\s]/, "") |> String.trim()
            %{state | researched_topics: MapSet.put(state.researched_topics, normalized)}

          {:error, _reason} ->
            state
        end
      else
        record_trace(state, :thought, %{
          source: "web_learning_skipped",
          question: question,
          resolution: thought_result.resolution,
          confidence: thought_result.confidence
        })
        state
      end
    else
      state
    end
  end

  defp run_distillation_cycle(state) do
    # Placeholder for Phase 3 — enhanced distillation
    Logger.debug("[Brain] Distillation cycle (Phase 3 placeholder)")
    state
  end

  defp run_storage_check(state) do
    # Placeholder for Phase 4 — storage monitoring
    Logger.debug("[Brain] Storage check (Phase 4 placeholder)")
    state
  end

  defp get_silo_domains_for_activity do
    try do
      case Kudzu.Silo.list() do
        domains when is_list(domains) ->
          Enum.map(domains, fn
            {domain, _, _} -> domain
            domain when is_binary(domain) -> domain
            _ -> nil
          end) |> Enum.reject(&is_nil/1)
        _ -> []
      end
    catch
      _, _ -> []
    end
  end
end"""

content = content.replace(old_schedule, new_schedule)

# 5. Change init_hologram success to use activity_cycle
content = content.replace(
    "schedule_wake_cycle(new_state.cycle_interval)",
    "schedule_activity_cycle()"
)

# 6. Update moduledoc
content = content.replace(
    "Brain GenServer — desire-driven wake cycles with thinking-layer reasoning.",
    "Brain GenServer — always-awake autonomous learning with tiered reasoning."
)

with open(brain_path, "w") as f:
    f.write(content)

print("brain.ex patched successfully")
