defmodule KudzuWeb.MCP.Handlers.Hologram do
  @moduledoc "MCP handlers for hologram tools."

  alias Kudzu.{Application, Hologram, Constitution}

  @allowed_purposes ~w(api_spawned research assistant coordinator worker analyzer claude_memory claude_assistant claude_research claude_learning claude_project explorer thinker researcher librarian optimizer specialist)a
  @allowed_constitutions ~w(mesh_republic cautious open kudzu_evolve)a
  @allowed_trace_purposes ~w(observation thought memory discovery research learning session_context)a

  def handle("kudzu_list_holograms", params) do
    limit = Map.get(params, "limit", 100)
    holograms = Registry.select(Kudzu.Registry, [{{{:id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.take(limit)
    |> Enum.map(fn {id, pid} ->
      try do
        state = Hologram.get_state(pid)
        %{id: id, purpose: state.purpose, constitution: state.constitution,
          trace_count: map_size(state.traces), peer_count: map_size(state.peers)}
      rescue
        _ -> %{id: id, alive: false}
      end
    end)
    {:ok, %{holograms: holograms, count: length(holograms)}}
  end

  def handle("kudzu_create_hologram", params) do
    opts = [
      purpose: find_atom(params["purpose"], @allowed_purposes, :api_spawned),
      constitution: find_atom(params["constitution"], @allowed_constitutions, :mesh_republic),
      desires: Map.get(params, "desires", []),
      cognition: Map.get(params, "cognition", false)
    ]
    case Application.spawn_hologram(opts) do
      {:ok, pid} ->
        id = Hologram.get_id(pid)
        {:ok, %{id: id, purpose: opts[:purpose], constitution: opts[:constitution]}}
      {:error, reason} ->
        {:error, -32603, "Failed to spawn: #{inspect(reason)}"}
    end
  end

  def handle("kudzu_get_hologram", %{"id" => id}) do
    with_hologram(id, fn pid ->
      state = Hologram.get_state(pid)
      {:ok, %{id: state.id, purpose: state.purpose, constitution: state.constitution,
        desires: state.desires, trace_count: map_size(state.traces),
        peer_count: map_size(state.peers), cognition_enabled: state.cognition_enabled}}
    end)
  end

  def handle("kudzu_delete_hologram", %{"id" => id}) do
    with_hologram(id, fn pid ->
      GenServer.stop(pid, :normal)
      {:ok, %{deleted: true, id: id}}
    end)
  end

  def handle("kudzu_stimulate_hologram", %{"id" => id, "stimulus" => stimulus} = params) do
    with_hologram(id, fn pid ->
      opts = Enum.reject([
        timeout: Map.get(params, "timeout", 120_000),
        model: Map.get(params, "model")
      ], fn {_k, v} -> is_nil(v) end)
      case Hologram.stimulate(pid, stimulus, opts) do
        {:ok, response, actions} ->
          {:ok, %{response: response, actions: length(actions), hologram_id: id}}
        {:error, reason} ->
          {:error, -32603, "Stimulation failed: #{inspect(reason)}"}
      end
    end)
  end

  def handle("kudzu_hologram_traces", %{"id" => id} = params) do
    with_hologram(id, fn pid ->
      traces = Hologram.recall_all(pid)
      traces = if p = params["purpose"] do
        purpose_atom = find_atom(p, @allowed_trace_purposes, nil)
        if purpose_atom, do: Enum.filter(traces, &(&1.purpose == purpose_atom)), else: traces
      else
        traces
      end
      traces = Enum.take(traces, Map.get(params, "limit", 100))
      {:ok, %{traces: Enum.map(traces, &trace_to_map/1), count: length(traces)}}
    end)
  end

  def handle("kudzu_record_trace", %{"id" => id, "purpose" => purpose, "data" => data}) do
    with_hologram(id, fn pid ->
      purpose_atom = find_atom(purpose, @allowed_trace_purposes, :observation)
      case Hologram.record_trace(pid, purpose_atom, data) do
        {:ok, trace} -> {:ok, %{trace: trace_to_map(trace)}}
        {:error, reason} -> {:error, -32603, "Failed: #{inspect(reason)}"}
      end
    end)
  end

  def handle("kudzu_hologram_peers", %{"id" => id}) do
    with_hologram(id, fn pid ->
      state = Hologram.get_state(pid)
      peers = Enum.map(state.peers, fn {peer_id, info} ->
        %{id: peer_id, trust: info.trust, last_seen: info.last_seen}
      end)
      {:ok, %{peers: peers}}
    end)
  end

  def handle("kudzu_add_hologram_peer", %{"id" => id, "peer_id" => peer_id}) do
    with_hologram(id, fn pid ->
      case Registry.lookup(Kudzu.Registry, {:id, peer_id}) do
        [{peer_pid, _}] ->
          Hologram.introduce_peer(pid, peer_pid)
          {:ok, %{added: true, peer_id: peer_id}}
        [] ->
          {:error, -32602, "Peer hologram not found"}
      end
    end)
  end

  def handle("kudzu_get_hologram_constitution", %{"id" => id}) do
    with_hologram(id, fn pid ->
      constitution = Hologram.get_constitution(pid)
      principles = Constitution.principles(constitution)
      {:ok, %{constitution: constitution, principles: principles}}
    end)
  end

  def handle("kudzu_set_hologram_constitution", %{"id" => id, "constitution" => c}) do
    with_hologram(id, fn pid ->
      atom = find_atom(c, @allowed_constitutions, :mesh_republic)
      case Hologram.set_constitution(pid, atom) do
        :ok -> {:ok, %{updated: true, constitution: atom}}
        {:error, reason} -> {:error, -32603, "Failed: #{inspect(reason)}"}
      end
    end)
  end

  def handle("kudzu_get_hologram_desires", %{"id" => id}) do
    with_hologram(id, fn pid ->
      state = Hologram.get_state(pid)
      {:ok, %{desires: state.desires}}
    end)
  end

  def handle("kudzu_add_hologram_desire", %{"id" => id, "desire" => desire}) do
    with_hologram(id, fn pid ->
      Hologram.add_desire(pid, desire)
      {:ok, %{added: true, desire: desire}}
    end)
  end

  defp with_hologram(id, fun) do
    case Registry.lookup(Kudzu.Registry, {:id, id}) do
      [{pid, _}] -> fun.(pid)
      [] -> {:error, -32602, "Hologram not found: #{id}"}
    end
  end

  defp find_atom(nil, _allowed, default), do: default
  defp find_atom(str, allowed, default) when is_binary(str) do
    normalized = str |> String.trim() |> String.downcase()
    Enum.find(allowed, default, fn atom -> Atom.to_string(atom) == normalized end)
  end

  defp trace_to_map(%Kudzu.Trace{} = t) do
    %{id: t.id, origin: t.origin, purpose: t.purpose,
      path: t.path, reconstruction_hint: t.reconstruction_hint}
  end
  defp trace_to_map(t) when is_map(t), do: t
end
