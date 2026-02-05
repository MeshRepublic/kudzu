defmodule Kudzu.Application do
  @moduledoc """
  Kudzu Application supervisor tree.

  Provides:
  - Beam-let execution substrate (IO, scheduling, resources)
  - DynamicSupervisor for spawning holograms on demand
  - Registry for hologram discovery by id and by purpose
  - Telemetry supervision for observability

  Architecture: Beam-lets start first as the execution substrate,
  then holograms can be spawned to use them for IO operations.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for hologram discovery
      # Keys: {:id, hologram_id} or {:purpose, purpose_atom}
      {Registry, keys: :duplicate, name: Kudzu.Registry},

      # Beam-let execution substrate (must start before holograms)
      {Kudzu.Beamlet.Supervisor, []},

      # DynamicSupervisor for spawning holograms on demand
      {DynamicSupervisor, strategy: :one_for_one, name: Kudzu.HologramSupervisor},

      # Telemetry supervisor for metrics
      {Kudzu.Telemetry, []}
    ]

    opts = [strategy: :one_for_one, name: Kudzu.Supervisor]
    Supervisor.start_link(children, opts)
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
  @spec find_by_id(String.t()) :: {:ok, pid()} | {:error, :not_found}
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
end
