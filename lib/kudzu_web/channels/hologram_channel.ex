defmodule KudzuWeb.HologramChannel do
  @moduledoc """
  WebSocket channel for real-time hologram interaction.

  Join a channel for a specific hologram:
    socket.channel("hologram:abc123", {})

  Or join a channel to create a new hologram:
    socket.channel("hologram:new", {purpose: "assistant"})

  Messages:
    - stimulate: Send stimulus to hologram
    - get_state: Get current hologram state
    - add_desire: Add a desire
    - recall: Query traces

  Server pushes:
    - trace_recorded: New trace was recorded
    - peer_message: Message from a peer hologram
    - constitution_changed: Constitution was changed
  """

  use Phoenix.Channel
  require Logger

  alias Kudzu.{Hologram, Application}

  @impl true
  def join("hologram:new", params, socket) do
    # Create a new hologram for this connection
    opts = [
      purpose: get_atom_param(params, "purpose", :websocket_session),
      constitution: get_atom_param(params, "constitution", :mesh_republic),
      desires: Map.get(params, "desires", []),
      cognition: Map.get(params, "cognition", true)
    ]

    case Application.spawn_hologram(opts) do
      {:ok, pid} ->
        id = Hologram.get_id(pid)
        socket = socket
        |> assign(:hologram_pid, pid)
        |> assign(:hologram_id, id)

        # Subscribe to hologram events
        Phoenix.PubSub.subscribe(Kudzu.PubSub, "hologram:#{id}")

        {:ok, %{hologram_id: id, purpose: opts[:purpose]}, socket}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  def join("hologram:" <> hologram_id, _params, socket) do
    case find_hologram(hologram_id) do
      {:ok, pid} ->
        socket = socket
        |> assign(:hologram_pid, pid)
        |> assign(:hologram_id, hologram_id)

        # Subscribe to hologram events
        Phoenix.PubSub.subscribe(Kudzu.PubSub, "hologram:#{hologram_id}")

        state = Hologram.get_state(pid)
        {:ok, %{
          hologram_id: hologram_id,
          purpose: state.purpose,
          constitution: state.constitution,
          trace_count: map_size(state.traces)
        }, socket}

      :error ->
        {:error, %{reason: "Hologram not found"}}
    end
  end

  @impl true
  def handle_in("stimulate", %{"content" => content} = params, socket) do
    pid = socket.assigns.hologram_pid
    opts = [
      timeout: Map.get(params, "timeout", 120_000)
    ]

    # Run stimulation asynchronously to not block the channel
    Task.start(fn ->
      case Hologram.stimulate(pid, content, opts) do
        {:ok, response, traces} ->
          push(socket, "stimulate_response", %{
            response: response,
            traces: Enum.map(traces, &trace_to_map/1)
          })

        {:error, reason} ->
          push(socket, "stimulate_error", %{error: inspect(reason)})
      end
    end)

    {:reply, {:ok, %{status: "processing"}}, socket}
  end

  def handle_in("get_state", _params, socket) do
    pid = socket.assigns.hologram_pid
    state = Hologram.get_state(pid)

    {:reply, {:ok, %{
      id: state.id,
      purpose: state.purpose,
      constitution: state.constitution,
      desires: state.desires,
      trace_count: map_size(state.traces),
      peer_count: map_size(state.peers)
    }}, socket}
  end

  def handle_in("add_desire", %{"desire" => desire}, socket) do
    pid = socket.assigns.hologram_pid
    Hologram.add_desire(pid, desire)
    {:reply, {:ok, %{added: desire}}, socket}
  end

  def handle_in("recall", params, socket) do
    pid = socket.assigns.hologram_pid
    purpose = Map.get(params, "purpose")
    limit = Map.get(params, "limit", 50)

    traces = Hologram.recall_all(pid)
    |> filter_by_purpose(purpose)
    |> Enum.take(limit)
    |> Enum.map(&trace_to_map/1)

    {:reply, {:ok, %{traces: traces}}, socket}
  end

  def handle_in("add_peer", %{"peer_id" => peer_id}, socket) do
    pid = socket.assigns.hologram_pid

    case find_hologram(peer_id) do
      {:ok, peer_pid} ->
        Hologram.introduce_peer(pid, peer_pid)
        {:reply, {:ok, %{added: peer_id}}, socket}

      :error ->
        {:reply, {:error, %{reason: "Peer not found"}}, socket}
    end
  end

  def handle_in("set_constitution", %{"constitution" => constitution}, socket) do
    pid = socket.assigns.hologram_pid
    constitution_atom = safe_to_constitution(constitution)

    case Hologram.set_constitution(pid, constitution_atom) do
      :ok ->
        {:reply, {:ok, %{constitution: constitution_atom}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_info({:trace_recorded, trace}, socket) do
    push(socket, "trace_recorded", %{trace: trace_to_map(trace)})
    {:noreply, socket}
  end

  def handle_info({:peer_message, from_id, message}, socket) do
    push(socket, "peer_message", %{from: from_id, message: message})
    {:noreply, socket}
  end

  def handle_info({:constitution_changed, from, to}, socket) do
    push(socket, "constitution_changed", %{from: from, to: to})
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Optionally stop the hologram when the connection closes
    # For now, let holograms persist
    Logger.debug("WebSocket disconnected for hologram #{socket.assigns[:hologram_id]}")
    :ok
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
      reconstruction_hint: trace.reconstruction_hint
    }
  end
  defp trace_to_map(map) when is_map(map), do: map

  defp filter_by_purpose(traces, nil), do: traces
  defp filter_by_purpose(traces, purpose) when is_binary(purpose) do
    purpose_atom = String.to_existing_atom(purpose)
    Enum.filter(traces, fn t -> t.purpose == purpose_atom end)
  rescue
    ArgumentError -> traces
  end

  defp get_atom_param(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      val when is_atom(val) -> val
      val when is_binary(val) -> String.to_existing_atom(val)
    end
  rescue
    ArgumentError -> default
  end

  @allowed_constitutions ~w(mesh_republic cautious open kudzu_evolve)a
  defp safe_to_constitution(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @allowed_constitutions, do: atom, else: :mesh_republic
  rescue
    ArgumentError -> :mesh_republic
  end
end
