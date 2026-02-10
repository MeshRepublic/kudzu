defmodule KudzuWeb.TraceController do
  use Phoenix.Controller

  alias Kudzu.{Hologram, Distributed}

  @doc """
  List traces across all local holograms.
  GET /api/v1/traces
  """
  def index(conn, params) do
    purpose_filter = Map.get(params, "purpose")
    limit = Map.get(params, "limit", "100") |> String.to_integer()

    # Collect traces from all holograms (select pids from :id entries)
    traces = Registry.select(Kudzu.Registry, [{{{:id, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn pid ->
      try do
        Hologram.recall_all(pid)
      rescue
        _ -> []
      end
    end)
    |> filter_by_purpose(purpose_filter)
    |> Enum.take(limit)
    |> Enum.map(&trace_to_map/1)

    json(conn, %{traces: traces, count: length(traces)})
  end

  @doc """
  Get a specific trace by ID.
  GET /api/v1/traces/:id
  """
  def show(conn, %{"id" => trace_id}) do
    # Search all holograms for this trace
    result = Registry.select(Kudzu.Registry, [{{{:id, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.find_value(fn pid ->
      try do
        traces = Hologram.recall_all(pid)
        Enum.find(traces, fn t -> t.id == trace_id end)
      rescue
        _ -> nil
      end
    end)

    case result do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Trace not found"})

      trace ->
        json(conn, %{trace: trace_to_map(trace)})
    end
  end

  @doc """
  Share a trace between holograms.
  POST /api/v1/traces/share
  """
  def share(conn, %{"from_hologram_id" => from_id, "to_hologram_id" => to_id, "trace_id" => trace_id}) do
    with {:ok, from_pid} <- find_hologram(from_id),
         {:ok, to_pid} <- find_hologram(to_id) do
      case Distributed.share_trace(from_pid, to_pid, trace_id) do
        :ok ->
          json(conn, %{shared: true, trace_id: trace_id, from: from_id, to: to_id})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to share trace", reason: inspect(reason)})
      end
    else
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

  defp filter_by_purpose(traces, nil), do: traces
  defp filter_by_purpose(traces, purpose) do
    purpose_atom = String.to_existing_atom(purpose)
    Enum.filter(traces, fn t -> t.purpose == purpose_atom end)
  rescue
    ArgumentError -> traces
  end
end
