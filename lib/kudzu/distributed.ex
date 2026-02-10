defmodule Kudzu.Distributed do
  @moduledoc """
  Distributed Kudzu over Tailscale or any network.

  Enables holograms to communicate across machines using Erlang distribution.
  Each Kudzu node can connect to others via Tailscale IP addresses.

  ## Setup

  1. Ensure Tailscale is running on all machines:
     ```
     tailscale status
     ```

  2. Start Kudzu nodes with names based on Tailscale IPs:
     ```bash
     # On machine 1
     iex --name kudzu@<your-tailscale-ip> --cookie <your-cookie> -S mix

     # On machine 2
     iex --name kudzu@<other-tailscale-ip> --cookie <your-cookie> -S mix
     ```

  3. Connect nodes:
     ```elixir
     Kudzu.Distributed.connect("kudzu@<other-tailscale-ip>")
     ```

  4. Spawn remote holograms:
     ```elixir
     {:ok, h} = Kudzu.Distributed.spawn_remote(:"kudzu@<other-tailscale-ip>",
       purpose: :remote_researcher,
       ollama_url: "http://<other-tailscale-ip>:11434"
     )
     ```

  ## Architecture

  Each node runs its own Kudzu application with local holograms.
  Nodes connect via Erlang distribution (encrypted over Tailscale).
  Remote holograms can be controlled via proxy PIDs.
  Traces can be shared across nodes.
  """

  require Logger

  @doc """
  Connect to a remote Kudzu node.

  ## Example
      Kudzu.Distributed.connect("kudzu@<remote-node-ip>")
  """
  @spec connect(atom() | String.t()) :: boolean() | {:error, term()}
  def connect(node) when is_binary(node), do: connect(String.to_atom(node))
  def connect(node) when is_atom(node) do
    case Node.connect(node) do
      true ->
        Logger.info("[Distributed] Connected to #{node}")
        true
      false ->
        Logger.warning("[Distributed] Failed to connect to #{node}")
        false
      :ignored ->
        {:error, :local_node_not_alive}
    end
  end

  @doc """
  List all connected Kudzu nodes.
  """
  @spec nodes() :: [atom()]
  def nodes do
    Node.list()
  end

  @doc """
  Check if we're running as a distributed node.
  """
  @spec distributed?() :: boolean()
  def distributed? do
    Node.alive?()
  end

  @doc """
  Get the current node name.
  """
  @spec self() :: atom()
  def self do
    Node.self()
  end

  @doc """
  Spawn a hologram on a remote node.

  Returns a local proxy PID that forwards calls to the remote hologram.

  ## Example
      {:ok, h} = Kudzu.Distributed.spawn_remote(:"kudzu@<remote-node-ip>",
        purpose: :researcher,
        ollama_url: "http://<remote-node-ip>:11434"
      )
  """
  @spec spawn_remote(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_remote(node, opts \\ []) do
    case :rpc.call(node, Kudzu.Application, :spawn_hologram, [opts]) do
      {:ok, remote_pid} ->
        # Create a local proxy for convenience
        {:ok, proxy} = start_proxy(node, remote_pid)
        {:ok, proxy}
      {:badrpc, reason} ->
        {:error, {:remote_spawn_failed, reason}}
      error ->
        error
    end
  end

  @doc """
  Get the ID of a hologram (local or remote).
  """
  @spec get_id(pid()) :: String.t()
  def get_id(hologram) do
    if local?(hologram) do
      Kudzu.Hologram.get_id(hologram)
    else
      call_remote(hologram, :get_id, [])
    end
  end

  @doc """
  Stimulate a hologram (local or remote).
  """
  @spec stimulate(pid(), String.t(), keyword()) :: {:ok, String.t(), list()} | {:error, term()}
  def stimulate(hologram, stimulus, opts \\ []) do
    if local?(hologram) do
      Kudzu.Hologram.stimulate(hologram, stimulus, opts)
    else
      call_remote(hologram, :stimulate, [stimulus, opts], 120_000)
    end
  end

  @doc """
  Share a trace from one hologram to another, potentially across nodes.
  """
  @spec share_trace(pid(), pid(), String.t()) :: :ok | {:error, term()}
  def share_trace(from_hologram, to_hologram, trace_id) do
    # Get the trace from source
    traces = if local?(from_hologram) do
      Kudzu.Hologram.recall_all(from_hologram)
    else
      call_remote(from_hologram, :recall_all, [])
    end

    case Enum.find(traces, & &1.id == trace_id) do
      nil ->
        {:error, :trace_not_found}
      trace ->
        # Send to destination
        from_id = get_id(from_hologram)
        if local?(to_hologram) do
          Kudzu.Hologram.receive_trace(to_hologram, trace, from_id)
        else
          call_remote(to_hologram, :receive_trace, [trace, from_id])
        end
    end
  end

  @doc """
  List holograms on a specific node.
  """
  @spec list_holograms(atom()) :: [pid()]
  def list_holograms(node \\ Node.self()) do
    if node == Node.self() do
      # Local
      Registry.select(Kudzu.HologramRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
    else
      :rpc.call(node, Registry, :select, [Kudzu.HologramRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}]])
    end
  end

  @doc """
  Broadcast a trace to all holograms across all connected nodes.
  """
  @spec broadcast_trace(map(), String.t()) :: :ok
  def broadcast_trace(trace, from_id) do
    all_nodes = [Node.self() | Node.list()]

    Enum.each(all_nodes, fn node ->
      holograms = list_holograms(node)
      Enum.each(holograms, fn h ->
        if node == Node.self() do
          Kudzu.Hologram.receive_trace(h, trace, from_id)
        else
          :rpc.cast(node, Kudzu.Hologram, :receive_trace, [h, trace, from_id])
        end
      end)
    end)

    :ok
  end

  @doc """
  Get cluster-wide statistics.
  """
  @spec cluster_stats() :: map()
  def cluster_stats do
    all_nodes = [Node.self() | Node.list()]

    stats = Enum.map(all_nodes, fn node ->
      holograms = list_holograms(node)
      {node, %{
        hologram_count: length(holograms),
        ollama_available: check_ollama(node)
      }}
    end)

    %{
      nodes: length(all_nodes),
      total_holograms: Enum.sum(Enum.map(stats, fn {_, s} -> s.hologram_count end)),
      per_node: Map.new(stats)
    }
  end

  # Private functions

  defp local?(pid) do
    node(pid) == Node.self()
  end

  defp call_remote(pid, func, args, timeout \\ 5000) do
    :rpc.call(node(pid), Kudzu.Hologram, func, [pid | args], timeout)
  end

  defp check_ollama(node) do
    if node == Node.self() do
      Kudzu.Cognition.available?()
    else
      case :rpc.call(node, Kudzu.Cognition, :available?, [], 5000) do
        {:badrpc, _} -> false
        result -> result
      end
    end
  end

  # Proxy GenServer for remote holograms
  defp start_proxy(node, remote_pid) do
    GenServer.start(Kudzu.Distributed.Proxy, {node, remote_pid})
  end
end

defmodule Kudzu.Distributed.Proxy do
  @moduledoc false
  use GenServer

  def init({node, remote_pid}) do
    # Monitor the remote process
    ref = Node.monitor(node, true)
    {:ok, %{node: node, remote_pid: remote_pid, monitor_ref: ref}}
  end

  def handle_call(request, _from, %{node: node, remote_pid: pid} = state) do
    result = :rpc.call(node, GenServer, :call, [pid, request], 60_000)
    {:reply, result, state}
  end

  def handle_cast(request, %{node: node, remote_pid: pid} = state) do
    :rpc.cast(node, GenServer, :cast, [pid, request])
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, %{node: node} = state) do
    {:stop, {:nodedown, node}, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
