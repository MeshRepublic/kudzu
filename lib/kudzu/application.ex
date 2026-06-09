defmodule Kudzu.Application do
  @moduledoc """
  Kudzu Application supervisor tree.

  Provides:
  - Beam-let execution substrate (IO, scheduling, resources)
  - DynamicSupervisor for spawning holograms on demand
  - Registry for hologram discovery by id and by purpose
  - Telemetry supervision for observability
  - Tiered storage: ETS (hot) → DETS (warm) → Mnesia (cold)
  - Memory consolidation daemon (biomimetic processing)

  Architecture: Beam-lets start first as the execution substrate,
  then holograms can be spawned to use them for IO operations.
  The consolidation daemon runs in the background, processing
  memories similar to how biological systems consolidate during sleep.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    ensure_nx_backend()
    Kudzu.HTTP.ensure_started()

    role = System.get_env("KUDZU_ROLE", "full")

    core_children = [
      {Registry, keys: :duplicate, name: Kudzu.Registry},
      {Phoenix.PubSub, name: Kudzu.PubSub},
      {Kudzu.Storage, []},
      {Kudzu.Node, []},
      {Kudzu.Beamlet.Supervisor, []},
      {Kudzu.HologramRegistry, []},
      {DynamicSupervisor, strategy: :one_for_one, name: Kudzu.HologramSupervisor},
      {Kudzu.Telemetry, []},
      {Kudzu.Cognition.KnownTraces, []},
      {Kudzu.Consolidation, []}
    ]

    full_children = if role == "worker" do
      Logger.info("[Application] Starting as WORKER node (no Brain, no web endpoint)")
      []
    else
      [Kudzu.Brain.ActivityIndicator, Kudzu.Brain, KudzuWeb.MCP.Session, KudzuWeb.MCP.Endpoint]
    end

    children = core_children ++ full_children

    opts = [strategy: :one_for_one, name: Kudzu.Supervisor]
    result = Supervisor.start_link(children, opts)

    # After supervisor tree is fully started, reconstruct persisted holograms
    case result do
      {:ok, _pid} ->
        install_signal_handler()

        Task.start(fn ->
          # Small delay to ensure all services are ready
          Process.sleep(1000)
          try do
            reconstructed = Kudzu.HologramRegistry.reconstruct_all()
            Logger.info("[Application] Reconstructed #{length(reconstructed)} holograms on startup")
          rescue
            e -> Logger.warning("[Application] Hologram reconstruction failed: #{inspect(e)}")
          end
        end)

      _ ->
        :ok
    end

    result
  end

  # Catch systemd SIGTERM (and SIGINT/SIGQUIT) and translate them into a graceful
  # System.stop/1 instead of letting -noshell mode drop them on the floor.
  # See lib/kudzu/signal_handler.ex for the gen_event handler body.
  defp install_signal_handler do
    # NOTE: :os.set_signal/2 only accepts a fixed set of signal names; :sigint is not
    # in OTP's allowlist, and :sigquit is owned by Elixir's System.SignalHandler for
    # interactive test-runner debugging. systemd uses SIGTERM, so that is sufficient.
    :ok = :os.set_signal(:sigterm, :handle)

    case :gen_event.add_handler(:erl_signal_server, Kudzu.SignalHandler, []) do
      :ok ->
        Logger.info("[Application] Signal handler installed (SIGTERM → graceful shutdown)")

      {:error, reason} ->
        Logger.warning("[Application] Signal handler install failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[Application] Signal handler setup error: #{inspect(e)}")
  end

  @doc """
  Spawn a new hologram under the DynamicSupervisor.

  ## Options
    - :id - unique identifier (generated if not provided)
    - :purpose - what this hologram is for
  """
  @spec spawn_hologram(keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_hologram(opts \\ []) do
    DynamicSupervisor.start_child(Kudzu.HologramSupervisor, {Kudzu.Hologram, opts})
  end

  @doc """
  Spawn multiple holograms concurrently.
  Returns list of {id, pid} tuples.
  """
  @spec spawn_holograms(non_neg_integer(), keyword()) :: [{String.t(), pid()}]
  def spawn_holograms(count, opts \\ []) do
    1..count
    |> Task.async_stream(
      fn _ ->
        {:ok, pid} = spawn_hologram(opts)
        id = Kudzu.Hologram.get_id(pid)
        {id, pid}
      end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  @doc """
  Stop a hologram by pid.
  """
  @spec stop_hologram(pid()) :: :ok | {:error, :not_found}
  def stop_hologram(pid) do
    DynamicSupervisor.terminate_child(Kudzu.HologramSupervisor, pid)
  end

  @doc """
  Find a hologram by ID.
  """
  @spec find_by_id(String.t()) :: {:ok, pid()} | {:error, term()}
  def find_by_id(id) do
    case Registry.lookup(Kudzu.Registry, {:id, id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Find all holograms with a given purpose.
  Returns list of {pid, id} tuples.
  """
  @spec find_by_purpose(atom() | String.t()) :: [{pid(), String.t()}]
  def find_by_purpose(purpose) do
    Registry.lookup(Kudzu.Registry, {:purpose, purpose})
  end

  @doc """
  Get count of active holograms.
  """
  @spec hologram_count() :: non_neg_integer()
  def hologram_count do
    DynamicSupervisor.count_children(Kudzu.HologramSupervisor).active
  end

  @doc """
  List all active hologram PIDs.
  """
  @spec list_holograms() :: [pid()]
  def list_holograms do
    DynamicSupervisor.which_children(Kudzu.HologramSupervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  # --- EXLA Startup Watchdog ---
  # EXLA is runtime: false in mix.exs, so it won't auto-start.
  # Config starts with Nx.BinaryBackend as safe default.
  # This function tries to manually start EXLA and upgrade if it works.
  defp ensure_nx_backend do
    task = Task.async(fn ->
      try do
        # Try to start EXLA manually (it's runtime: false so not auto-started)
        case Application.ensure_all_started(:exla) do
          {:ok, _} ->
            # EXLA started, now test a tensor operation
            Application.put_env(:nx, :default_backend, EXLA.Backend)
            Application.put_env(:nx, :default_defn_options, [compiler: EXLA])
            t = Nx.tensor([1.0, 2.0, 3.0])
            Nx.to_flat_list(t)
            :ok
          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e -> {:error, e}
      end
    end)

    case Task.yield(task, 15_000) || Task.shutdown(task) do
      {:ok, :ok} ->
        Logger.info("[Application] EXLA backend initialized successfully")
        Application.put_env(:kudzu, :hrr_backend, Kudzu.HRR.NxBackend)

      {:ok, {:error, reason}} ->
        Logger.warning("[Application] EXLA unavailable: #{inspect(reason)}, using binary backend")
        fallback_to_binary_backend()

      nil ->
        Logger.warning("[Application] EXLA timed out (15s), using binary backend")
        fallback_to_binary_backend()
    end
  end

  defp fallback_to_binary_backend do
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)
    Application.put_env(:nx, :default_defn_options, [])
    Application.put_env(:kudzu, :hrr_backend, nil)
  end
end
