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

  def temporal(conn, params) do
    with {:ok, from_dt} <- parse_datetime(params["from"]),
         {:ok, to_dt} <- parse_datetime(params["to"]) do
      opts = case params["purpose"] do
        nil -> []
        p -> [purpose: String.to_existing_atom(p)]
      end
      results = Kudzu.Storage.query_temporal(from_dt, to_dt, opts)

      json(conn, %{
        traces: Enum.map(results, &serialize_record/1),
        count: length(results)
      })
    else
      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Invalid from/to datetime. Use ISO 8601."})
    end
  end

  defp parse_datetime(nil), do: {:error, :missing}
  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :invalid}
    end
  end

  defp serialize_record(record) do
    %{
      id: record.id,
      hologram_id: record.hologram_id,
      purpose: record.purpose,
      content: record.reconstruction_hint,
      created_at: DateTime.to_iso8601(record.created_at),
      importance: record.importance
    }
  end
end
