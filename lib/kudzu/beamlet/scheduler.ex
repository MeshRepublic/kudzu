defmodule Kudzu.Beamlet.Scheduler do
  @moduledoc """
  Scheduler Beam-let - provides scheduling hints and work distribution.

  Helps holograms coordinate work without central orchestration:
  - Priority hints for time-sensitive operations
  - Work queue management
  - Backpressure signaling
  - Load distribution suggestions
  """

  use Kudzu.Beamlet.Base, capabilities: [:scheduling, :priority, :work_queue]

  require Logger

  @impl Kudzu.Beamlet.Behaviour
  def handle_request(%{op: :schedule_work, work: work, priority: priority}, from_id) do
    Logger.debug("Scheduler: work from #{from_id} priority #{priority}")

    # In a real implementation, this would manage a priority queue
    # For now, just acknowledge and suggest when to execute
    delay = case priority do
      :immediate -> 0
      :high -> 10
      :normal -> 100
      :low -> 1000
      :background -> 5000
      _ -> 100
    end

    work_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    {:ok, %{
      work_id: work_id,
      scheduled: true,
      suggested_delay_ms: delay,
      queue_position: :rand.uniform(10)  # Simulated
    }}
  end

  def handle_request(%{op: :get_priority_hint, task_type: task_type}, from_id) do
    # Provide priority hints based on task type and system load
    hint = case task_type do
      :cognition -> :normal  # LLM calls are slow anyway
      :io -> :high  # IO should be responsive
      :trace_share -> :normal
      :peer_query -> :high
      :background_maintenance -> :low
      _ -> :normal
    end

    {:ok, %{priority: hint, reason: "default_policy"}}
  end

  def handle_request(%{op: :report_backpressure, level: level}, from_id) do
    Logger.info("Scheduler: backpressure #{level} from #{from_id}")
    # Could trigger load shedding, scaling, etc.
    {:ok, :acknowledged}
  end

  def handle_request(%{op: :suggest_peer, capability: capability, exclude: exclude}, _from_id) do
    # Help find a good peer for work distribution
    case Kudzu.Beamlet.Supervisor.find_by_capability(capability) do
      [] ->
        {:ok, %{suggestion: nil, reason: :no_beamlets}}

      beamlets ->
        # Filter and find best
        available = beamlets
        |> Enum.reject(fn {_pid, id} -> id in (exclude || []) end)
        |> Enum.map(fn {pid, id} ->
          try do
            load = GenServer.call(pid, :get_load, 500)
            {pid, id, load}
          catch
            :exit, _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_, _, load} -> load end)

        case available do
          [] -> {:ok, %{suggestion: nil, reason: :all_overloaded}}
          [{_pid, id, load} | _] -> {:ok, %{suggestion: id, load: load}}
        end
    end
  end

  def handle_request(%{op: :rate_limit_check, key: key, limit: limit, window_ms: window}, _from_id) do
    # Simple rate limiting check
    # In production, would use ETS or Redis for shared state
    now = System.system_time(:millisecond)

    # For now, just approve (would track in state)
    {:ok, %{allowed: true, remaining: limit - 1, reset_at: now + window}}
  end

  def handle_request(req, from_id) do
    Logger.warning("Scheduler: unknown request #{inspect(req)} from #{from_id}")
    {:error, :unknown_operation}
  end

  def init_beamlet(state, _opts) do
    # Could initialize rate limit tracking, work queues, etc.
    Map.merge(state, %{
      work_queues: %{},
      rate_limits: %{}
    })
  end
end
