defmodule Kudzu.Beamlet.Supervisor do
  @moduledoc """
  Supervisor for beam-let execution substrate.

  Manages the lifecycle of beam-lets that provide capabilities to holograms:
  - IO beam-lets (file, network, external APIs)
  - Scheduler beam-lets (priority hints, work distribution)
  - Resource beam-lets (memory, compute allocation)

  Beam-lets are supervised separately from holograms - execution substrate
  and purpose agents have independent lifecycles.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for beam-let discovery by capability
      {Registry, keys: :duplicate, name: Kudzu.BeamletRegistry},

      # DynamicSupervisor for spawning beam-lets on demand
      {DynamicSupervisor, strategy: :one_for_one, name: Kudzu.Beamlet.DynamicSupervisor},

      # Default IO beam-let (can spawn more for load balancing)
      {Kudzu.Beamlet.IO, [id: "io-primary"]},

      # Scheduler beam-let for work distribution hints
      {Kudzu.Beamlet.Scheduler, [id: "scheduler-primary"]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Spawn an additional beam-let of the given type.
  """
  def spawn_beamlet(module, opts \\ []) do
    DynamicSupervisor.start_child(
      Kudzu.Beamlet.DynamicSupervisor,
      {module, opts}
    )
  end

  @doc """
  Find beam-lets by capability.
  Returns list of {pid, id} tuples.
  """
  def find_by_capability(capability) do
    Registry.lookup(Kudzu.BeamletRegistry, {:capability, capability})
  end

  @doc """
  Find a beam-let by ID.
  """
  def find_by_id(id) do
    case Registry.lookup(Kudzu.BeamletRegistry, {:id, id}) do
      [{pid, _caps}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Find the best beam-let for a capability based on load.
  Returns {:ok, pid} or {:error, :no_available_beamlet}.
  """
  def find_best(capability) do
    case find_by_capability(capability) do
      [] ->
        {:error, :no_available_beamlet}

      beamlets ->
        # Find healthiest, least loaded beam-let
        best = beamlets
        |> Enum.map(fn {pid, id} ->
          try do
            load = GenServer.call(pid, :get_load, 1000)
            healthy = GenServer.call(pid, :healthy?, 1000)
            {pid, id, load, healthy}
          catch
            :exit, _ -> {pid, id, 1.0, false}
          end
        end)
        |> Enum.filter(fn {_, _, _, healthy} -> healthy end)
        |> Enum.min_by(fn {_, _, load, _} -> load end, fn -> nil end)

        case best do
          nil -> {:error, :no_healthy_beamlet}
          {pid, _id, _load, _} -> {:ok, pid}
        end
    end
  end

  @doc """
  Get status of all beam-lets.
  """
  def status do
    # Get all capabilities being tracked
    capabilities = [:file_read, :file_write, :http_get, :http_post, :shell_exec, :scheduling]

    capabilities
    |> Enum.map(fn cap ->
      beamlets = find_by_capability(cap)
      |> Enum.map(fn {pid, id} ->
        try do
          info = GenServer.call(pid, :info, 1000)
          {id, info}
        catch
          :exit, _ -> {id, %{status: :unreachable}}
        end
      end)

      {cap, beamlets}
    end)
    |> Map.new()
  end

  @doc """
  Scale beam-lets of a type to a target count.
  """
  def scale(module, target_count) do
    capability = hd(module.capabilities())
    current = find_by_capability(capability)
    current_count = length(current)

    cond do
      current_count < target_count ->
        # Spawn more
        to_spawn = target_count - current_count
        for i <- 1..to_spawn do
          spawn_beamlet(module, [id: "#{capability}-#{System.unique_integer([:positive])}"])
        end
        {:ok, :scaled_up, to_spawn}

      current_count > target_count ->
        # Kill extras (keep the first target_count)
        {_keep, to_kill} = Enum.split(current, target_count)
        Enum.each(to_kill, fn {pid, _id} ->
          DynamicSupervisor.terminate_child(Kudzu.Beamlet.DynamicSupervisor, pid)
        end)
        {:ok, :scaled_down, length(to_kill)}

      true ->
        {:ok, :no_change, 0}
    end
  end
end
