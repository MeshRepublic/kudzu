defmodule KudzuWeb.MCP.Handlers.Trace do
  @moduledoc "MCP handlers for trace tools."

  alias Kudzu.{Hologram, Application}

  def handle("kudzu_list_traces", params) do
    purpose_filter = params["purpose"]
    limit = Map.get(params, "limit", 100)

    traces = Application.list_holograms()
    |> Enum.flat_map(fn pid ->
      try do
        Hologram.recall_all(pid)
      rescue
        _ -> []
      end
    end)
    |> then(fn traces ->
      if purpose_filter do
        purpose_atom = String.to_existing_atom(purpose_filter)
        Enum.filter(traces, &(&1.purpose == purpose_atom))
      else
        traces
      end
    end)
    |> Enum.take(limit)

    {:ok, %{traces: Enum.map(traces, &trace_to_map/1), count: length(traces)}}
  rescue
    ArgumentError -> {:ok, %{traces: [], count: 0}}
  end

  def handle("kudzu_get_trace", %{"id" => trace_id}) do
    result = Application.list_holograms()
    |> Enum.find_value(fn pid ->
      try do
        Hologram.recall_all(pid) |> Enum.find(&(&1.id == trace_id))
      rescue
        _ -> nil
      end
    end)

    case result do
      nil -> {:error, -32602, "Trace not found: #{trace_id}"}
      trace -> {:ok, trace_to_map(trace)}
    end
  end

  def handle("kudzu_share_trace", %{"trace_id" => trace_id, "from_id" => from_id, "to_id" => to_id}) do
    with [{from_pid, _}] <- Registry.lookup(Kudzu.Registry, {:id, from_id}),
         [{to_pid, _}] <- Registry.lookup(Kudzu.Registry, {:id, to_id}) do
      trace = Hologram.recall_all(from_pid) |> Enum.find(&(&1.id == trace_id))
      if trace do
        Hologram.receive_trace(to_pid, trace, from_id)
        {:ok, %{shared: true, trace_id: trace_id, from: from_id, to: to_id}}
      else
        {:error, -32602, "Trace not found in source hologram"}
      end
    else
      _ -> {:error, -32602, "Hologram not found"}
    end
  end

  defp trace_to_map(%Kudzu.Trace{} = t) do
    %{id: t.id, origin: t.origin, purpose: t.purpose,
      path: t.path, reconstruction_hint: t.reconstruction_hint}
  end
  defp trace_to_map(t) when is_map(t), do: t
end
