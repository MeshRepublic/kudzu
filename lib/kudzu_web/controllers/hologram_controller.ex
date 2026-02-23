defmodule KudzuWeb.HologramController do
  use Phoenix.Controller
  require Logger

  alias Kudzu.{Application, Hologram, Constitution}

  @doc """
  List all holograms.
  GET /api/v1/holograms
  """
  def index(conn, params) do
    limit = Map.get(params, "limit", "100") |> String.to_integer()

    # Select only :id entries to get hologram id and pid
    holograms = Registry.select(Kudzu.Registry, [{{{:id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.take(limit)
    |> Enum.map(fn {id, pid} ->
      try do
        state = Hologram.get_state(pid)
        %{
          id: id,
          pid: inspect(pid),
          purpose: state.purpose,
          constitution: state.constitution,
          trace_count: map_size(state.traces),
          peer_count: map_size(state.peers),
          alive: Process.alive?(pid)
        }
      rescue
        _ -> %{id: id, pid: inspect(pid), alive: false}
      end
    end)

    json(conn, %{holograms: holograms, count: length(holograms)})
  end

  @doc """
  Show a specific hologram.
  GET /api/v1/holograms/:id
  """
  def show(conn, %{"id" => id}) do
    case find_hologram(id) do
      {:ok, pid} ->
        state = Hologram.get_state(pid)
        json(conn, %{
          hologram: %{
            id: state.id,
            pid: inspect(pid),
            purpose: state.purpose,
            constitution: state.constitution,
            desires: state.desires,
            trace_count: map_size(state.traces),
            peer_count: map_size(state.peers),
            clock: Kudzu.VectorClock.to_map(state.clock),
            cognition_enabled: state.cognition_enabled
          }
        })

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Spawn a new hologram.
  POST /api/v1/holograms
  """
  def create(conn, params) do
    opts = [
      purpose: get_atom_param(params, "purpose", :api_spawned),
      constitution: get_atom_param(params, "constitution", :mesh_republic),
      desires: Map.get(params, "desires", []),
      cognition: Map.get(params, "cognition", false),
      ollama_url: Map.get(params, "ollama_url")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Application.spawn_hologram(opts) do
      {:ok, pid} ->
        id = Hologram.get_id(pid)

        # Register in persistent registry so it survives restarts
        Kudzu.HologramRegistry.register(id, %{
          purpose: opts[:purpose],
          constitution: opts[:constitution],
          desires: opts[:desires] || [],
          cognition_enabled: opts[:cognition] || false,
          cognition_model: Keyword.get(opts, :model, "mistral:latest")
        })

        conn
        |> put_status(:created)
        |> json(%{
          hologram: %{
            id: id,
            pid: inspect(pid),
            purpose: opts[:purpose],
            constitution: opts[:constitution]
          }
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to spawn hologram", reason: inspect(reason)})
    end
  end

  @doc """
  Delete (stop) a hologram.
  DELETE /api/v1/holograms/:id
  """
  def delete(conn, %{"id" => id}) do
    case find_hologram(id) do
      {:ok, pid} ->
        # Deregister from persistent registry before stopping
        Kudzu.HologramRegistry.deregister(id)
        GenServer.stop(pid, :normal)
        json(conn, %{deleted: true, id: id})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Send a stimulus to a hologram.
  POST /api/v1/holograms/:id/stimulate
  """
  def stimulate(conn, %{"hologram_id" => id} = params) do
    stimulus = Map.get(params, "stimulus", Map.get(params, "content", ""))

    opts = [
      timeout: Map.get(params, "timeout", 120_000),
      model: Map.get(params, "model")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case find_hologram(id) do
      {:ok, pid} ->
        case Hologram.stimulate(pid, stimulus, opts) do
          {:ok, response, actions} ->
            json(conn, %{
              response: response,
              actions: Enum.map(actions, &action_to_map/1),
              hologram_id: id
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Stimulation failed", reason: inspect(reason)})
        end

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Record a trace to a hologram.
  POST /api/v1/holograms/:id/traces
  """
  def record_trace(conn, %{"hologram_id" => id} = params) do
    purpose = get_trace_purpose(params)
    data = Map.get(params, "data", %{})

    case find_hologram(id) do
      {:ok, pid} ->
        case Hologram.record_trace(pid, purpose, data) do
          {:ok, trace} ->
            conn
            |> put_status(:created)
            |> json(%{trace: trace_to_map(trace)})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to record trace", reason: inspect(reason)})
        end

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Get traces from a hologram.
  GET /api/v1/holograms/:id/traces
  """
  def traces(conn, %{"hologram_id" => id} = params) do
    purpose_filter = Map.get(params, "purpose")
    limit = Map.get(params, "limit", "100") |> String.to_integer()

    case find_hologram(id) do
      {:ok, pid} ->
        traces = Hologram.recall_all(pid)
        |> filter_by_purpose(purpose_filter)
        |> Enum.take(limit)
        |> Enum.map(&trace_to_map/1)

        json(conn, %{traces: traces, count: length(traces)})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Get peers of a hologram.
  GET /api/v1/holograms/:id/peers
  """
  def peers(conn, %{"hologram_id" => id}) do
    case find_hologram(id) do
      {:ok, pid} ->
        state = Hologram.get_state(pid)
        peers = Enum.map(state.peers, fn {peer_id, info} ->
          %{id: peer_id, trust: info.trust, last_seen: info.last_seen}
        end)
        json(conn, %{peers: peers})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Add a peer to a hologram.
  POST /api/v1/holograms/:id/peers
  """
  def add_peer(conn, %{"hologram_id" => id, "peer_id" => peer_id}) do
    case {find_hologram(id), find_hologram(peer_id)} do
      {{:ok, pid}, {:ok, peer_pid}} ->
        Hologram.introduce_peer(pid, peer_pid)
        # Persist peer change (will be captured by periodic persist_all_live)
        json(conn, %{added: true, peer_id: peer_id})

      {{:ok, _}, :error} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Peer hologram not found"})

      {:error, _} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Get hologram's constitution.
  GET /api/v1/holograms/:id/constitution
  """
  def get_constitution(conn, %{"hologram_id" => id}) do
    case find_hologram(id) do
      {:ok, pid} ->
        constitution = Hologram.get_constitution(pid)
        principles = Constitution.principles(constitution)
        json(conn, %{constitution: constitution, principles: principles})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Set hologram's constitution.
  PUT /api/v1/holograms/:id/constitution
  """
  def set_constitution(conn, %{"hologram_id" => id, "constitution" => constitution}) do
    constitution_atom = safe_to_constitution_atom(constitution)

    case find_hologram(id) do
      {:ok, pid} ->
        case Hologram.set_constitution(pid, constitution_atom) do
          :ok ->
            json(conn, %{updated: true, constitution: constitution_atom})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to set constitution", reason: inspect(reason)})
        end

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Get hologram's desires.
  GET /api/v1/holograms/:id/desires
  """
  def get_desires(conn, %{"hologram_id" => id}) do
    case find_hologram(id) do
      {:ok, pid} ->
        state = Hologram.get_state(pid)
        json(conn, %{desires: state.desires})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  @doc """
  Add a desire to a hologram.
  POST /api/v1/holograms/:id/desires
  """
  def add_desire(conn, %{"hologram_id" => id, "desire" => desire}) do
    case find_hologram(id) do
      {:ok, pid} ->
        Hologram.add_desire(pid, desire)
        json(conn, %{added: true, desire: desire})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hologram not found"})
    end
  end

  # Helper functions

  defp find_hologram(id) do
    case Registry.lookup(Kudzu.Registry, {:id, id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp trace_to_map(%Kudzu.Trace{} = trace) do
    %{
      id: trace.id,
      origin: trace.origin,
      purpose: trace.purpose,
      path: trace.path,
      reconstruction_hint: trace.reconstruction_hint,
      timestamp: Kudzu.VectorClock.to_map(trace.timestamp)
    }
  end
  defp trace_to_map(trace) when is_map(trace) do
    %{
      id: trace[:id] || trace["id"],
      origin: trace[:origin] || trace["origin"],
      purpose: trace[:purpose] || trace["purpose"],
      path: trace[:path] || trace["path"] || [],
      reconstruction_hint: trace[:reconstruction_hint] || trace["reconstruction_hint"] || %{}
    }
  end

  defp filter_by_purpose(traces, nil), do: traces
  defp filter_by_purpose(traces, purpose) do
    purpose_atom = String.to_existing_atom(purpose)
    Enum.filter(traces, fn t -> t.purpose == purpose_atom end)
  rescue
    ArgumentError -> traces
  end

  defp action_to_map({:record_trace, purpose, hints}) do
    %{type: "record_trace", purpose: purpose, hints: hints}
  end
  defp action_to_map({:query_peer, peer_id, purpose}) do
    %{type: "query_peer", peer_id: peer_id, purpose: purpose}
  end
  defp action_to_map({:share_trace, peer_id, trace_id}) do
    %{type: "share_trace", peer_id: peer_id, trace_id: trace_id}
  end
  defp action_to_map({:update_desire, desire}) do
    %{type: "update_desire", desire: desire}
  end
  defp action_to_map({:respond, message}) do
    %{type: "respond", message: message}
  end
  defp action_to_map(:noop), do: %{type: "noop"}
  defp action_to_map(other), do: %{type: "unknown", raw: inspect(other)}

  @allowed_trace_purposes ~w(observation thought memory discovery research learning session_context)a
  defp get_trace_purpose(params) do
    case Map.get(params, "purpose") do
      nil -> :observation
      purpose when is_binary(purpose) ->
        find_allowed_atom(purpose, @allowed_trace_purposes, :observation)
    end
  end

  defp get_atom_param(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      val when is_atom(val) -> val
      val when is_binary(val) -> safe_to_atom(val, default)
    end
  end

  @allowed_purposes ~w(api_spawned research assistant coordinator worker analyzer claude_memory claude_assistant claude_research claude_learning claude_project explorer thinker researcher librarian optimizer specialist)a
  defp safe_to_atom(str, default) do
    find_allowed_atom(str, @allowed_purposes, default)
  end

  # Find matching atom from allowlist by comparing strings
  defp find_allowed_atom(str, allowlist, default) do
    normalized = str |> String.trim() |> String.downcase()
    Enum.find(allowlist, default, fn atom ->
      Atom.to_string(atom) == normalized
    end)
  end

  @allowed_constitutions ~w(mesh_republic cautious open kudzu_evolve)a
  defp safe_to_constitution_atom(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @allowed_constitutions, do: atom, else: :mesh_republic
  rescue
    ArgumentError -> :mesh_republic
  end
  defp safe_to_constitution_atom(atom) when is_atom(atom), do: atom
end
