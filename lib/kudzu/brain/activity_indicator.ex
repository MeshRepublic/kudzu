defmodule Kudzu.Brain.ActivityIndicator do
  @moduledoc """
  Animated terminal spinner showing Brain activity in real-time.

  Processes register activities with start_activity/2 and clear them
  with stop_activity/1. The spinner redraws every 80ms while active.
  """

  use GenServer
  require Logger

  @tick_ms 80
  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @colors %{
    learning: "\e[36m",    # cyan
    reasoning: "\e[33m",   # yellow
    curiosity: "\e[35m",   # magenta
    health: "\e[32m",      # green
    distilling: "\e[34m",  # blue
    default: "\e[37m"      # white
  }
  @reset "\e[0m"
  @dim "\e[2m"

  defstruct activities: %{}, frame: 0, timer: nil

  # ── Client API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an active activity. Shows in the spinner until stopped.

  ## Examples

      ActivityIndicator.start_activity(:learning, "bash commands via ollama_teacher")
      ActivityIndicator.start_activity(:reasoning, "analyzing anomaly")
  """
  @spec start_activity(atom(), String.t()) :: :ok
  def start_activity(id, description) do
    GenServer.cast(__MODULE__, {:start, id, description})
  catch
    :exit, _ -> :ok
  end

  @doc "Stop an activity by id."
  @spec stop_activity(atom()) :: :ok
  def stop_activity(id) do
    GenServer.cast(__MODULE__, {:stop, id})
  catch
    :exit, _ -> :ok
  end

  @doc "List currently active activities."
  @spec active() :: [map()]
  def active do
    GenServer.call(__MODULE__, :active)
  catch
    :exit, _ -> []
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:start, id, description}, state) do
    activity = %{
      description: description,
      started_at: System.monotonic_time(:millisecond),
      category: categorize(id)
    }

    new_activities = Map.put(state.activities, id, activity)
    state = %{state | activities: new_activities}

    # Start ticking if this is the first activity
    state = if map_size(state.activities) == 1 and is_nil(state.timer) do
      timer = Process.send_after(self(), :tick, @tick_ms)
      %{state | timer: timer}
    else
      state
    end

    {:noreply, state}
  end

  def handle_cast({:stop, id}, state) do
    {removed, new_activities} = Map.pop(state.activities, id)

    if removed do
      # Clear the spinner line
      IO.write("\r\e[2K")
    end

    state = %{state | activities: new_activities}

    # Stop ticking if no activities left
    state = if map_size(state.activities) == 0 and state.timer do
      Process.cancel_timer(state.timer)
      %{state | timer: nil}
    else
      state
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:active, _from, state) do
    list = Enum.map(state.activities, fn {id, act} ->
      elapsed = System.monotonic_time(:millisecond) - act.started_at
      %{id: id, description: act.description, elapsed_ms: elapsed}
    end)
    {:reply, list, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if map_size(state.activities) > 0 do
      render(state)
      timer = Process.send_after(self(), :tick, @tick_ms)
      {:noreply, %{state | frame: state.frame + 1, timer: timer}}
    else
      IO.write("\r\e[2K")
      {:noreply, %{state | timer: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Rendering ───────────────────────────────────────────────────

  defp render(state) do
    frame_char = Enum.at(@frames, rem(state.frame, length(@frames)))
    now = System.monotonic_time(:millisecond)

    parts = state.activities
      |> Enum.sort_by(fn {_id, act} -> act.started_at end)
      |> Enum.map(fn {_id, act} ->
        elapsed = div(now - act.started_at, 1000)
        color = Map.get(@colors, act.category, @colors.default)
        time_str = format_elapsed(elapsed)
        "#{color}#{act.description}#{@reset} #{@dim}#{time_str}#{@reset}"
      end)

    line = case parts do
      [single] ->
        " #{frame_char} #{single}"
      multiple ->
        first = hd(multiple)
        rest_count = length(multiple) - 1
        " #{frame_char} #{first} #{@dim}(+#{rest_count} more)#{@reset}"
    end

    # Truncate to terminal width (assume 120 cols, strip ANSI for length check)
    IO.write("\r\e[2K#{line}")
  end

  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_elapsed(seconds) do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}m#{String.pad_leading("#{s}", 2, "0")}s"
  end

  defp categorize(id) do
    id_str = to_string(id)
    cond do
      String.contains?(id_str, "learn") -> :learning
      String.contains?(id_str, "reason") -> :reasoning
      String.contains?(id_str, "curiosity") -> :curiosity
      String.contains?(id_str, "health") -> :health
      String.contains?(id_str, "distill") -> :distilling
      true -> :default
    end
  end
end
