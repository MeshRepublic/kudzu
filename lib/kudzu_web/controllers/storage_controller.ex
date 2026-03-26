defmodule KudzuWeb.StorageController do
  use Phoenix.Controller, formats: [:json]

  def stats(conn, _params) do
    basic = Kudzu.Storage.stats()
    detailed = Kudzu.Storage.detailed_stats()

    result = %{
      tiers: %{
        hot: %{count: basic.hot, bytes: detailed.hot_bytes},
        warm: %{count: basic.warm, bytes: detailed.warm_bytes},
        cold: %{count: basic.cold, ready: basic.mnesia_ready}
      },
      totals: %{
        bytes: detailed.total_bytes,
        utilization_pct: detailed.utilization,
        max_bytes: detailed.max_total_bytes
      },
      embeddings: %{
        count: Kudzu.Storage.embedding_count()
      },
      limits: %{
        max_hot_entries: detailed.max_hot_entries,
        max_warm_bytes: detailed.max_warm_bytes,
        max_total_bytes: detailed.max_total_bytes
      }
    }

    json(conn, result)
  end
end
