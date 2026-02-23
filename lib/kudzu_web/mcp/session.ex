defmodule KudzuWeb.MCP.Session do
  @moduledoc "MCP session management backed by ETS."
  use GenServer

  @table :mcp_sessions
  @ttl_ms 30 * 60 * 1000
  @sweep_interval 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def create do
    session_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    :ets.insert(@table, {session_id, System.monotonic_time(:millisecond)})
    {:ok, session_id}
  end

  def valid?(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, _last_active}] -> true
      [] -> false
    end
  end

  def touch(session_id) do
    :ets.update_element(@table, session_id, {2, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def destroy(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @ttl_ms
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
