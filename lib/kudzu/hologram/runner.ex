defmodule Kudzu.Hologram.Runner do
  @moduledoc """
  Autonomous activity loop for a hologram.

  Wraps a hologram with a periodic activity cycle that:
  1. Reads the hologram's desires
  2. Picks the most actionable desire
  3. Executes an appropriate action (research, reason, observe, report)
  4. Records findings as traces on the hologram
  5. Checks constitutional constraints before each action

  Multiple Runners can exist simultaneously (unlike Brain, which is a singleton).
  Each Runner is supervised under DynamicSupervisor for crash recovery.
  """

  use GenServer
  require Logger

  alias Kudzu.{Constitution, Hologram}
  alias Kudzu.Brain.Vectors.Router, as: VectorRouter

  @default_cycle_interval 60_000
  @research_cooldown 300_000
  @max_cycles 50

  defstruct [
    :hologram_pid,
    :hologram_id,
    :swarm_id,
    :task,
    cycle_interval: @default_cycle_interval,
    cycle_count: 0,
    max_cycles: @max_cycles,
    status: :initializing,
    last_research: nil,
    findings: [],
    research_active: false
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(pid), do: GenServer.stop(pid, :normal)

  def status(pid), do: GenServer.call(pid, :status)

  def get_findings(pid), do: GenServer.call(pid, :get_findings)

  # Server

  @impl true
  def init(opts) do
    hologram_pid = Keyword.fetch!(opts, :hologram_pid)
    hologram_id = Keyword.fetch!(opts, :hologram_id)

    state = %__MODULE__{
      hologram_pid: hologram_pid,
      hologram_id: hologram_id,
      swarm_id: Keyword.get(opts, :swarm_id),
      task: Keyword.get(opts, :task),
      cycle_interval: Keyword.get(opts, :cycle_interval, @default_cycle_interval),
      max_cycles: Keyword.get(opts, :max_cycles, @max_cycles),
      status: :active
    }

    Logger.info("[Runner:#{short_id(hologram_id)}] Started — task: #{state.task || "autonomous"}")
    schedule_cycle(state.cycle_interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:activity_cycle, %{status: :stopped} = state) do
    {:noreply, state}
  end

  def handle_info(:activity_cycle, %{status: :completed} = state) do
    {:noreply, state}
  end

  def handle_info(:activity_cycle, state) do
    if state.cycle_count >= state.max_cycles do
      Logger.info(
        "[Runner:#{short_id(state.hologram_id)}] Max cycles (#{state.max_cycles}) reached — completing"
      )

      # Record completion trace
      try do
        Hologram.record_trace(state.hologram_pid, :memory, %{
          type: "runner_completed",
          swarm_id: state.swarm_id,
          task: state.task,
          cycles: state.cycle_count,
          findings_count: length(state.findings)
        })
      catch
        _, _ -> :ok
      end

      {:noreply, %{state | status: :completed}}
    else
      state = run_cycle(state)
      schedule_cycle(state.cycle_interval)
      {:noreply, %{state | cycle_count: state.cycle_count + 1}}
    end
  end

  def handle_info(:research_done, state) do
    {:noreply, %{state | research_active: false}}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    info = %{
      hologram_id: state.hologram_id,
      swarm_id: state.swarm_id,
      task: state.task,
      status: state.status,
      cycle_count: state.cycle_count,
      max_cycles: state.max_cycles,
      findings_count: length(state.findings),
      research_active: state.research_active
    }

    {:reply, info, state}
  end

  def handle_call(:get_findings, _from, state) do
    {:reply, state.findings, state}
  end

  # HologramRegistry calls :get_state on all HologramSupervisor children.
  # Return a minimal map so it doesn't crash, but mark us as a Runner.
  def handle_call(:get_state, _from, state) do
    {:reply, %{__struct__: __MODULE__, id: state.hologram_id, purpose: :runner}, state}
  end

  # Catch-all for any other unexpected calls
  def handle_call(_msg, _from, state) do
    {:reply, {:error, :not_hologram}, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info(
      "[Runner:#{short_id(state.hologram_id)}] Stopping after #{state.cycle_count} cycles"
    )

    :ok
  end

  # Activity cycle

  defp run_cycle(state) do
    old_trap = Process.flag(:trap_exit, true)

    state =
      try do
        desires = get_desires(state)

        cond do
          # If we have a specific task, research it
          state.task != nil and not state.research_active and research_cooldown_ok?(state) ->
            run_research(state, state.task)

          # If desires mention research/learn/explore
          (desire = find_research_desire(desires)) != nil ->
            if not state.research_active and research_cooldown_ok?(state) do
              run_research(state, desire)
            else
              run_reasoning(state, desire)
            end

          # Default: reason about whatever we know
          true ->
            topic = List.first(desires) || state.task || "reflect on accumulated knowledge"
            run_reasoning(state, topic)
        end
      catch
        kind, reason ->
          Logger.warning(
            "[Runner:#{short_id(state.hologram_id)}] Cycle crashed: #{inspect(kind)}: #{inspect(reason) |> String.slice(0, 200)}"
          )

          state
      after
        Process.flag(:trap_exit, old_trap)

        receive do
          {:EXIT, _pid, _reason} -> :ok
        after
          0 -> :ok
        end
      end

    state
  end

  defp run_research(state, topic) do
    case check_constitution(state, :web_research) do
      :permitted ->
        now = System.monotonic_time(:millisecond)
        runner_pid = self()
        holo_pid = state.hologram_pid
        holo_id = state.hologram_id

        Task.start(fn ->
          try do
            Logger.info(
              "[Runner:#{short_id(holo_id)}] Researching: #{String.slice(to_string(topic), 0, 80)}"
            )

            case VectorRouter.learn(to_string(topic)) do
              {:ok, result} ->
                Logger.info(
                  "[Runner:#{short_id(holo_id)}] Research done via #{Map.get(result, :vector, "unknown")}"
                )

                try do
                  Hologram.record_trace(holo_pid, :discovery, %{
                    type: "research_finding",
                    topic: to_string(topic),
                    vector: Map.get(result, :vector, "unknown"),
                    content_preview: result.content |> String.slice(0, 200)
                  })
                catch
                  _, _ -> :ok
                end

              {:error, reason} ->
                Logger.warning(
                  "[Runner:#{short_id(holo_id)}] Research failed: #{inspect(reason) |> String.slice(0, 200)}"
                )
            end
          catch
            kind, reason ->
              Logger.warning(
                "[Runner:#{short_id(holo_id)}] Research crashed: #{inspect(kind)}: #{inspect(reason) |> String.slice(0, 200)}"
              )
          end

          send(runner_pid, :research_done)
        end)

        %{state | research_active: true, last_research: now}

      {:denied, reason} ->
        Logger.debug("[Runner:#{short_id(state.hologram_id)}] Research denied: #{reason}")
        state
    end
  end

  defp run_reasoning(state, topic) do
    case check_constitution(state, :reasoning) do
      :permitted ->
        try do
          result = Kudzu.Brain.Thought.run(to_string(topic), timeout: 10_000)

          if result != nil and result.chain != [] do
            finding = %{
              type: "inference",
              topic: to_string(topic),
              confidence: result.confidence,
              chain_length: length(result.chain),
              activations: length(result.activations)
            }

            Hologram.record_trace(state.hologram_pid, :thought, finding)
            %{state | findings: [finding | state.findings]}
          else
            state
          end
        catch
          _, _ -> state
        end

      {:denied, _} ->
        state
    end
  end

  # Helpers

  defp get_desires(state) do
    try do
      Hologram.get_desires(state.hologram_pid)
    catch
      _, _ -> []
    end
  end

  defp find_research_desire(desires) do
    Enum.find(desires, fn d ->
      d_lower = String.downcase(to_string(d))

      String.contains?(d_lower, "research") or
        String.contains?(d_lower, "learn") or
        String.contains?(d_lower, "explore") or
        String.contains?(d_lower, "investigate") or
        String.contains?(d_lower, "understand")
    end)
  end

  defp research_cooldown_ok?(state) do
    state.last_research == nil or
      System.monotonic_time(:millisecond) - state.last_research >= @research_cooldown
  end

  defp check_constitution(state, action) do
    try do
      constitution = Hologram.get_constitution(state.hologram_pid)
      holo_state = Hologram.get_state(state.hologram_pid)

      case Constitution.permitted?(constitution, action, holo_state) do
        :permitted -> :permitted
        {:denied, reason} -> {:denied, reason}
        {:requires_consensus, _} -> :permitted
      end
    catch
      _, _ -> :permitted
    end
  end

  defp schedule_cycle(interval) do
    Process.send_after(self(), :activity_cycle, interval)
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: inspect(id)
end
