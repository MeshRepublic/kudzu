defmodule Kudzu.Brain do
  @moduledoc """
  Brain GenServer — desire-driven wake cycles with three-tier reasoning.

  The Brain is the autonomous executive layer of Kudzu. It wakes periodically,
  runs health checks (the "pre-check gate"), and when anomalies are detected,
  reasons about them through a three-tier pipeline:

  1. **Tier 1 — Reflexes**: Instant pattern → action mappings, zero cost.
  2. **Tier 2 — Silo Inference**: HRR vector reasoning across expertise silos.
  3. **Tier 3 — Claude API**: LLM-driven reasoning for novel situations.

  ## Wake Cycle

  Every `cycle_interval` milliseconds (default 5 minutes), the Brain:

  1. Runs `pre_check/1` — a battery of health checks
  2. If all nominal → goes back to sleep
  3. If anomalies detected → enters the reasoning pipeline
  4. Schedules the next wake cycle

  ## Desires

  The Brain maintains a list of high-level desires that guide its reasoning.
  These are aspirational goals, not tasks — they shape what the Brain pays
  attention to and how it prioritizes anomalies.
  """

  use GenServer
  require Logger

  alias Kudzu.Brain.Reflexes
  alias Kudzu.Brain.InferenceEngine
  alias Kudzu.Brain.PromptBuilder

  @initial_desires [
    "Maintain Kudzu system health and recover from failures",
    "Build accurate self-model of architecture, resources, and capabilities",
    "Learn from every observation — discover patterns in system behavior",
    "Identify knowledge gaps and pursue self-education to fill them",
    "Plan for increased fault tolerance and distributed operation"
  ]

  @default_cycle_interval 300_000
  @init_delay 2_000
  @retry_delay 10_000
  @consolidation_staleness_ms 1_200_000

  defstruct [
    :hologram_id,
    :hologram_pid,
    :current_session,
    :budget,
    desires: @initial_desires,
    status: :sleeping,
    cycle_interval: @default_cycle_interval,
    cycle_count: 0,
    config: %{}
  ]

  # ── Client API ──────────────────────────────────────────────────────

  @doc "Start the Brain GenServer under supervision."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the current Brain state (for inspection and testing)."
  @spec get_state() :: %__MODULE__{}
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Force an immediate wake cycle outside the normal schedule."
  @spec wake_now() :: :ok
  def wake_now do
    GenServer.cast(__MODULE__, :wake_now)
  end

  # ── Server Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    config = %{
      model: "claude-sonnet-4-20250514",
      api_key: api_key,
      max_turns: 10,
      budget_limit_monthly: 100.0
    }

    state = %__MODULE__{config: config}

    # Schedule hologram initialization after a short delay so the rest of
    # the supervision tree has time to start.
    Process.send_after(self(), :init_hologram, @init_delay)

    Logger.info("[Brain] Started — scheduling hologram init in #{@init_delay}ms")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:wake_now, state) do
    send(self(), :wake_cycle)
    {:noreply, state}
  end

  @impl true
  def handle_info(:init_hologram, state) do
    case init_hologram() do
      {:ok, pid, id} ->
        Logger.info("[Brain] Hologram ready — id=#{id}")
        try do
          Kudzu.Brain.SelfModel.init()
          Logger.info("[Brain] Self-model silo initialized")
        catch
          kind, reason ->
            Logger.warning("[Brain] Self-model init failed: #{inspect({kind, reason})}")
        end
        new_state = %{state | hologram_pid: pid, hologram_id: id}
        schedule_wake_cycle(new_state.cycle_interval)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning(
          "[Brain] Hologram init failed: #{inspect(reason)} — retrying in #{@retry_delay}ms"
        )

        Process.send_after(self(), :init_hologram, @retry_delay)
        {:noreply, state}
    end
  end

  def handle_info(:wake_cycle, %{hologram_id: nil} = state) do
    Logger.debug("[Brain] Skipping wake cycle — no hologram attached")
    schedule_wake_cycle(state.cycle_interval)
    {:noreply, state}
  end

  def handle_info(:wake_cycle, state) do
    new_count = state.cycle_count + 1
    Logger.debug("[Brain] Wake cycle ##{new_count}")

    state = %{state | cycle_count: new_count, status: :reasoning}

    case pre_check(state) do
      :sleep ->
        Logger.debug("[Brain] Pre-check nominal — back to sleep")
        schedule_wake_cycle(state.cycle_interval)
        {:noreply, %{state | status: :sleeping}}

      {:wake, anomalies} ->
        Logger.info("[Brain] Cycle #{new_count}: #{length(anomalies)} anomalies")
        state = reason(state, anomalies)
        schedule_wake_cycle(state.cycle_interval)
        {:noreply, %{state | status: :sleeping}}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[Brain] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Three-Tier Reasoning Pipeline ──────────────────────────────────

  defp reason(state, anomalies) do
    tagged = Enum.map(anomalies, &{:anomaly, &1})

    # Tier 1: Reflexes — pattern → action, zero cost
    case Reflexes.check(tagged) do
      {:act, actions} ->
        Logger.info("[Brain] Tier 1: executing #{length(actions)} reflex actions")
        Enum.each(actions, &Reflexes.execute_action/1)

        record_trace(state, :decision, %{
          tier: "reflex",
          actions: Enum.map(actions, &inspect/1)
        })

        state

      {:escalate, alerts} ->
        record_trace(state, :observation, %{
          alert: true,
          severity: alert_severity(alerts),
          alerts: Enum.map(alerts, &ensure_map/1)
        })

        Logger.warning("[Brain] Escalation: #{inspect(alerts)}")
        # After escalation, try Tier 2/3 for resolution
        maybe_tier2_3(state, anomalies)

      :pass ->
        Logger.debug("[Brain] Reflexes passed — no pattern match")
        # Reflexes didn't match — try Tier 2 silo inference, then Tier 3 Claude
        maybe_tier2_3(state, anomalies)
    end
  end

  defp maybe_tier2_3(state, anomalies) do
    # Tier 2: Silo inference — check if any expertise silo has relevant knowledge
    silo_results = try_silo_inference(anomalies)

    case silo_results do
      {:found, findings} ->
        Logger.info("[Brain] Tier 2: silo inference found #{length(findings)} relevant facts")

        record_trace(state, :thought, %{
          tier: "silo_inference",
          findings: findings
        })

        state

      :no_match ->
        # Tier 3: Claude API — novel situation, needs LLM reasoning
        maybe_call_claude(state, anomalies)
    end
  end

  defp try_silo_inference(anomalies) do
    # Extract key terms from anomalies and probe silos
    terms =
      anomalies
      |> Enum.flat_map(fn anomaly ->
        reason = to_string(Map.get(anomaly, :reason, ""))
        check = to_string(Map.get(anomaly, :check, ""))
        [check | String.split(reason)]
      end)
      |> Enum.uniq()

    results =
      Enum.flat_map(terms, fn term ->
        InferenceEngine.cross_query(term)
      end)

    high_confidence =
      Enum.filter(results, fn {_domain, _hint, score} ->
        InferenceEngine.confidence(score) in [:high, :moderate]
      end)

    if high_confidence != [] do
      findings =
        Enum.map(high_confidence, fn {domain, hint, score} ->
          %{
            domain: domain,
            hint: ensure_map(hint),
            score: score,
            confidence: InferenceEngine.confidence(score)
          }
        end)

      {:found, Enum.take(findings, 10)}
    else
      :no_match
    end
  end

  defp maybe_call_claude(state, anomalies) do
    api_key = state.config[:api_key] || state.config["api_key"]

    if api_key do
      system_prompt = PromptBuilder.build(state)

      anomaly_desc =
        Enum.map(anomalies, fn a ->
          "#{a.check}: #{a.reason}"
        end)
        |> Enum.join("; ")

      message =
        "Anomalies detected that I couldn't handle with reflexes or silo inference:\n" <>
          anomaly_desc <>
          "\n\nWhat should I do?"

      tools = Kudzu.Brain.Tools.Introspection.to_claude_format()

      executor = fn name, params ->
        Kudzu.Brain.Tools.Introspection.execute(name, params)
      end

      case Kudzu.Brain.Claude.reason(
             api_key,
             system_prompt,
             message,
             tools,
             executor,
             max_turns: state.config[:max_turns] || 10,
             model: state.config[:model] || "claude-sonnet-4-20250514"
           ) do
        {:ok, response_text, usage} ->
          Logger.info(
            "[Brain] Tier 3 (#{usage.input_tokens}+#{usage.output_tokens} tokens): " <>
              String.slice(response_text, 0, 200)
          )

          record_trace(state, :thought, %{
            tier: "claude",
            response: String.slice(response_text, 0, 500),
            usage: usage
          })

          state

        {:error, reason} ->
          Logger.error("[Brain] Claude API error: #{inspect(reason)}")

          record_trace(state, :observation, %{
            error: "claude_api_failure",
            reason: inspect(reason)
          })

          state
      end
    else
      Logger.debug("[Brain] No API key configured, skipping Tier 3")
      state
    end
  end

  # ── Trace Recording ─────────────────────────────────────────────────

  defp record_trace(state, purpose, data) do
    if state.hologram_pid do
      try do
        Kudzu.Hologram.record_trace(state.hologram_pid, purpose, data)
      rescue
        _ -> :ok
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # Extract severity from the first alert in the list, defaulting to :unknown
  defp alert_severity([%{severity: sev} | _]), do: sev
  defp alert_severity(_), do: :unknown

  # Ensure a value is a plain map (not a struct) for trace serialization
  defp ensure_map(%_{} = struct), do: Map.from_struct(struct)
  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(other), do: %{value: inspect(other)}

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
        {:anomaly,
         %{check: :consolidation_recency, reason: "No consolidation has ever run"}}

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

  # ── Hologram Init ───────────────────────────────────────────────────

  defp init_hologram do
    case Kudzu.Application.find_by_purpose("kudzu_brain") do
      [{pid, id} | _] ->
        Logger.info("[Brain] Found existing kudzu_brain hologram: #{id}")
        {:ok, pid, id}

      [] ->
        Logger.info("[Brain] Spawning new kudzu_brain hologram")

        case Kudzu.Application.spawn_hologram(
               purpose: "kudzu_brain",
               desires: @initial_desires,
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

  # ── Scheduling ──────────────────────────────────────────────────────

  defp schedule_wake_cycle(interval) do
    Process.send_after(self(), :wake_cycle, interval)
  end
end
