defmodule Kudzu.Cognition.KnownTraces do
  @moduledoc """
  Per-`{hologram_id, model_id, session_id}` set of trace IDs already shown to
  a given LLM in a given session. The prompt builder consults this tracker
  before injecting a recalled trace into a prompt: if the model has already
  seen the trace this session, the builder emits a short reference instead of
  the full content, and the input-token cost of the trace is saved.

  ## Economic motivation

  Storage is cheap; data tokens are not, especially when an autonomous loop
  recalls the same trace turn after turn. At Sonnet 4.6 input pricing
  (~$3/M tokens) a 50-turn session that re-sends 200K tokens of context per
  turn costs ~$30; if KnownTraces lets the builder skip 80% of repeated
  context, that is ~$24/session saved. KnownTraces is the bookkeeping that
  closes the recall → prompt → bill loop.

  ## Implementation

  Backed by an ETS table (`:set`, `:protected`, `read_concurrency: true`)
  owned by this GenServer. The table key is `{hologram_id, model_id,
  session_id}` and the value is a `{MapSet.t(trace_id), last_used_monotonic
  :: integer()}` tuple. Reads (`seen?/4`) hit ETS directly from any process;
  writes (`mark_sent/4`) route through the GenServer to serialize set
  updates.

  Idle session state is evicted by a periodic sweep: rows whose
  `last_used_monotonic` is older than the configured TTL are deleted in
  one pass. Defaults: 6 h TTL, 30 min sweep cadence. Both are tunable via
  `:kudzu, :known_traces_ttl_ms` and `:kudzu, :known_traces_sweep_interval_ms`.

  ## Configuration

      config :kudzu,
        known_traces_ttl_ms: 6 * 60 * 60 * 1000,
        known_traces_sweep_interval_ms: 30 * 60 * 1000
  """

  use GenServer
  require Logger

  @table :kudzu_known_traces
  @default_ttl_ms 6 * 60 * 60 * 1000
  @default_sweep_interval_ms 30 * 60 * 1000

  @type hologram_id :: String.t()
  @type model_id :: atom() | String.t()
  @type session_id :: String.t()
  @type trace_id :: String.t()

  # ── Client API ──────────────────────────────────────────────────────────

  @doc "Start the KnownTraces GenServer under supervision."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Has `trace_id` already been shown to `model_id` in this `session_id`
  on `hologram_id`?

  Reads the ETS table directly without going through the GenServer, so this
  call is safe to fan out across many prompt-builder workers. Returns `false`
  if the GenServer is not running (best-effort during boot).
  """
  @spec seen?(hologram_id(), model_id(), session_id(), trace_id()) :: boolean()
  def seen?(hologram_id, model_id, session_id, trace_id) do
    key = {hologram_id, normalize_model(model_id), session_id}

    case safe_lookup(key) do
      {:ok, {trace_set, _last_used}} -> MapSet.member?(trace_set, trace_id)
      _ -> false
    end
  end

  @doc """
  Record that `trace_ids` have just been sent to `model_id` for `session_id`
  on `hologram_id`. Updates the `last_used` timestamp so the sweep won't
  evict an active session.

  Accepts a single trace_id or a list. No-op if the GenServer isn't running.
  """
  @spec mark_sent(hologram_id(), model_id(), session_id(), trace_id() | [trace_id()]) :: :ok
  def mark_sent(hologram_id, model_id, session_id, trace_id_or_ids)

  def mark_sent(hologram_id, model_id, session_id, trace_id) when is_binary(trace_id) do
    mark_sent(hologram_id, model_id, session_id, [trace_id])
  end

  def mark_sent(hologram_id, model_id, session_id, trace_ids) when is_list(trace_ids) do
    if alive?() do
      GenServer.cast(__MODULE__, {:mark_sent, hologram_id, normalize_model(model_id),
                                  session_id, trace_ids})
    end

    :ok
  end

  @doc """
  Forget all known-trace state for `{hologram_id, model_id, session_id}`.
  Used when a session ends or when an operator wants to force re-injection
  of full context next time.
  """
  @spec forget_session(hologram_id(), model_id(), session_id()) :: :ok
  def forget_session(hologram_id, model_id, session_id) do
    if alive?() do
      GenServer.call(__MODULE__, {:forget_session, hologram_id, normalize_model(model_id),
                                  session_id})
    else
      :ok
    end
  end

  @doc """
  Return a small snapshot of tracker stats for `/metrics` and ad-hoc
  inspection.

    * `:sessions` — number of `{hologram_id, model_id, session_id}` rows
    * `:traces_known` — sum of trace_set sizes across all rows
  """
  @spec stats() :: %{sessions: non_neg_integer(), traces_known: non_neg_integer()}
  def stats do
    if alive?() do
      :ets.foldl(
        fn {_key, {trace_set, _last_used}}, %{sessions: s, traces_known: t} ->
          %{sessions: s + 1, traces_known: t + MapSet.size(trace_set)}
        end,
        %{sessions: 0, traces_known: 0},
        @table
      )
    else
      %{sessions: 0, traces_known: 0}
    end
  end

  @doc """
  Run a sweep immediately (instead of waiting for the timer). Returns the
  number of rows evicted. Primarily a test helper, but also handy for
  ops manual eviction.
  """
  @spec sweep_now() :: non_neg_integer()
  def sweep_now do
    if alive?() do
      GenServer.call(__MODULE__, :sweep_now)
    else
      0
    end
  end

  @doc """
  Block until all previously-cast `mark_sent/4` updates have been applied.
  Useful in tests where a `seen?/4` follows a `mark_sent/4` and would
  otherwise race the GenServer mailbox.
  """
  @spec sync() :: :ok
  def sync do
    if alive?() do
      GenServer.call(__MODULE__, :sync)
    else
      :ok
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_sweep()
    Logger.debug("[KnownTraces] Started (ttl=#{ttl_ms()} ms, sweep=#{sweep_interval_ms()} ms)")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:mark_sent, hologram_id, model_id, session_id, trace_ids}, state) do
    key = {hologram_id, model_id, session_id}
    now = System.monotonic_time(:millisecond)

    new_set =
      case :ets.lookup(@table, key) do
        [{^key, {existing, _last_used}}] ->
          Enum.reduce(trace_ids, existing, &MapSet.put(&2, &1))

        [] ->
          Enum.reduce(trace_ids, MapSet.new(), &MapSet.put(&2, &1))
      end

    :ets.insert(@table, {key, {new_set, now}})
    {:noreply, state}
  end

  @impl true
  def handle_call({:forget_session, hologram_id, model_id, session_id}, _from, state) do
    :ets.delete(@table, {hologram_id, model_id, session_id})
    {:reply, :ok, state}
  end

  def handle_call(:sweep_now, _from, state) do
    {:reply, do_sweep(), state}
  end

  # Synchronous no-op used by tests (and ops) to drain any pending mark_sent
  # casts: by the time this reply arrives, every cast queued before the call
  # has been processed.
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    evicted = do_sweep()
    if evicted > 0, do: Logger.debug("[KnownTraces] Swept #{evicted} stale session rows")
    schedule_sweep()
    {:noreply, state}
  end

  # Unknown messages are ignored to keep the tracker robust against
  # spurious traffic (timers, debug pokes, etc.).
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internal ───────────────────────────────────────────────────────────

  @spec do_sweep() :: non_neg_integer()
  defp do_sweep do
    cutoff = System.monotonic_time(:millisecond) - ttl_ms()

    :ets.foldl(
      fn {key, {_set, last_used}}, evicted ->
        if last_used < cutoff do
          :ets.delete(@table, key)
          evicted + 1
        else
          evicted
        end
      end,
      0,
      @table
    )
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  defp ttl_ms do
    Application.get_env(:kudzu, :known_traces_ttl_ms, @default_ttl_ms)
  end

  defp sweep_interval_ms do
    Application.get_env(:kudzu, :known_traces_sweep_interval_ms, @default_sweep_interval_ms)
  end

  # Look up the ETS table only when it exists. Until init/1 has created the
  # named table (or after a crash before restart), the table is absent and
  # callers should see "unknown trace" rather than blow up.
  defp safe_lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        :no_table

      _tid ->
        case :ets.lookup(@table, key) do
          [{^key, value}] -> {:ok, value}
          [] -> :miss
        end
    end
  rescue
    ArgumentError -> :no_table
  end

  # Use `Process.whereis/1` rather than catching exceptions so we don't pay
  # for a try/rescue on every read-only call.
  defp alive? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # Atoms and strings both work as model identifiers; normalize to string for
  # consistent ETS key equality.
  defp normalize_model(model_id) when is_atom(model_id), do: Atom.to_string(model_id)
  defp normalize_model(model_id) when is_binary(model_id), do: model_id
end
