defmodule Kudzu.Telemetry do
  @moduledoc """
  Telemetry hooks for observing Kudzu agent behavior.

  Events emitted:
  - [:kudzu, :hologram, :start] - hologram started
  - [:kudzu, :hologram, :stop] - hologram stopped
  - [:kudzu, :hologram, :trace_recorded] - new trace recorded
  - [:kudzu, :hologram, :trace_received] - trace received from peer
  - [:kudzu, :hologram, :peer_introduced] - new peer relationship
  - [:kudzu, :hologram, :query] - query executed

  Attach handlers to observe system behavior in real-time.
  """

  use GenServer
  require Logger

  @events [
    [:kudzu, :hologram, :start],
    [:kudzu, :hologram, :stop],
    [:kudzu, :hologram, :trace_recorded],
    [:kudzu, :hologram, :trace_received],
    [:kudzu, :hologram, :peer_introduced]
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Attach default console handler if in dev/test
    if Application.get_env(:kudzu, :telemetry_console, false) do
      attach_console_handler()
    end

    {:ok, %{
      counters: %{
        holograms_started: 0,
        holograms_stopped: 0,
        traces_recorded: 0,
        traces_received: 0,
        peers_introduced: 0
      },
      handlers: []
    }}
  end

  @doc """
  Attach a handler function to all Kudzu telemetry events.
  Handler receives: (event_name, measurements, metadata)
  """
  @spec attach_handler(atom(), function()) :: :ok
  def attach_handler(handler_id, handler_fn) do
    :telemetry.attach_many(
      handler_id,
      @events,
      fn event, measurements, metadata, _config ->
        handler_fn.(event, measurements, metadata)
      end,
      nil
    )
  end

  @doc """
  Detach a handler by ID.
  """
  @spec detach_handler(atom()) :: :ok | {:error, :not_found}
  def detach_handler(handler_id) do
    :telemetry.detach(handler_id)
  end

  @doc """
  Attach the default console logging handler.
  """
  def attach_console_handler do
    attach_handler(:kudzu_console, fn event, measurements, metadata ->
      event_name = Enum.join(event, ".")
      Logger.debug("[#{event_name}] #{inspect(measurements)} #{inspect(metadata)}")
    end)
  end

  @doc """
  Get current telemetry statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Reset telemetry counters.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.counters, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | counters: %{
      holograms_started: 0,
      holograms_stopped: 0,
      traces_recorded: 0,
      traces_received: 0,
      peers_introduced: 0
    }}}
  end
end
