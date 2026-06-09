defmodule KudzuWeb.MetricsController do
  use Phoenix.Controller, formats: [:json]

  def index(conn, _params) do
    storage = Kudzu.Storage.detailed_stats()
    hologram_count = Kudzu.Application.hologram_count()
    embedding_count = Kudzu.Storage.embedding_count()

    consolidation_status = try do
      Kudzu.Consolidation.status()
    rescue
      _ -> %{status: :unknown}
    end

    brain_status = try do
      Kudzu.Brain.status()
    rescue
      _ -> %{status: :not_running}
    end

    known_traces_stats = try do
      Kudzu.Cognition.KnownTraces.stats()
    rescue
      _ -> %{sessions: 0, traces_known: 0}
    end

    metrics = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      storage: %{
        hot_count: storage.hot_count,
        hot_bytes: storage.hot_bytes,
        warm_bytes: storage.warm_bytes,
        total_bytes: storage.total_bytes,
        utilization_pct: storage.utilization,
        embedding_count: embedding_count
      },
      holograms: %{
        active_count: hologram_count
      },
      consolidation: consolidation_status,
      known_traces: known_traces_stats,
      brain: brain_status,
      node: %{
        uptime_seconds: node_uptime(),
        beam_memory_bytes: :erlang.memory(:total),
        process_count: :erlang.system_info(:process_count)
      }
    }

    json(conn, metrics)
  end

  defp node_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end
end
