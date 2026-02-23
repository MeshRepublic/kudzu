defmodule KudzuWeb.MCP.Handlers.Semantic do
  @moduledoc """
  MCP handlers for semantic memory tools.

  Uses the HRR Encoder V2 (token-seeded bundling with co-occurrence learning)
  to provide semantic retrieval, association lookup, and vocabulary inspection.
  """

  alias Kudzu.{Hologram, Application, HRR}
  alias Kudzu.HRR.{Encoder, EncoderState, Tokenizer}
  alias Kudzu.Consolidation

  def handle("kudzu_semantic_recall", params) do
    query = params["query"] || ""
    limit = Map.get(params, "limit", 10)
    purpose_filter = params["purpose"]
    threshold = Map.get(params, "threshold", 0.0)

    if query == "" do
      {:error, -32602, "Query text is required"}
    else
      # Get encoder state and codebook from consolidation daemon
      {codebook, encoder_state} = get_encoder_context()

      # Encode the query
      query_vec = Encoder.encode_query(query, codebook, encoder_state)

      # Collect all traces from all holograms
      all_traces = collect_all_traces(purpose_filter)

      # Encode each trace and compute similarity
      scored = all_traces
      |> Enum.map(fn {trace, hologram_id} ->
        trace_vec = Encoder.encode(trace, codebook, encoder_state)
        sim = HRR.similarity(query_vec, trace_vec)
        {trace, hologram_id, sim}
      end)
      |> Enum.filter(fn {_t, _h, sim} -> sim >= threshold end)
      |> Enum.sort_by(fn {_t, _h, sim} -> sim end, :desc)
      |> Enum.take(limit)

      results = Enum.map(scored, fn {trace, hologram_id, sim} ->
        %{
          similarity: Float.round(sim, 4),
          trace_id: trace.id,
          hologram_id: hologram_id,
          purpose: trace.purpose,
          content: extract_content_preview(trace.reconstruction_hint),
          reconstruction_hint: trace.reconstruction_hint
        }
      end)

      {:ok, %{
        query: query,
        results: results,
        count: length(results),
        encoder_stats: %{
          vocabulary_size: map_size(encoder_state.token_counts),
          traces_processed: encoder_state.traces_processed,
          blend_strength: encoder_state.blend_strength
        }
      }}
    end
  end

  def handle("kudzu_associations", params) do
    token = params["token"] || ""
    k = Map.get(params, "k", 10)

    if token == "" do
      {:error, -32602, "Token is required"}
    else
      {_codebook, encoder_state} = get_encoder_context()

      # Stem the input token to match how it's stored
      stemmed = Tokenizer.stem(String.downcase(token))

      neighbors = EncoderState.top_neighbors(encoder_state, stemmed, k: k)

      # Also get neighbors for the unstemmed form
      raw_neighbors = if stemmed != String.downcase(token) do
        EncoderState.top_neighbors(encoder_state, String.downcase(token), k: k)
      else
        []
      end

      all_neighbors = (neighbors ++ raw_neighbors)
      |> Enum.uniq_by(fn {t, _w} -> t end)
      |> Enum.sort_by(fn {_t, w} -> w end, :desc)
      |> Enum.take(k)

      token_count = Map.get(encoder_state.token_counts, stemmed, 0) +
                    Map.get(encoder_state.token_counts, String.downcase(token), 0)

      {:ok, %{
        token: token,
        stemmed: stemmed,
        occurrences: token_count,
        associations: Enum.map(all_neighbors, fn {t, w} ->
          %{token: t, weight: Float.round(w, 2)}
        end),
        count: length(all_neighbors)
      }}
    end
  end

  def handle("kudzu_vocabulary", params) do
    limit = Map.get(params, "limit", 50)
    query = params["query"]

    {_codebook, encoder_state} = get_encoder_context()

    tokens = encoder_state.token_counts
    |> then(fn counts ->
      if query do
        stemmed_query = Tokenizer.stem(String.downcase(query))
        Enum.filter(counts, fn {token, _count} ->
          String.contains?(token, String.downcase(query)) or
          String.contains?(token, stemmed_query)
        end)
      else
        counts
      end
    end)
    |> Enum.sort_by(fn {_t, c} -> c end, :desc)
    |> Enum.take(limit)

    {:ok, %{
      tokens: Enum.map(tokens, fn {token, count} ->
        %{token: token, count: count}
      end),
      total_vocabulary: map_size(encoder_state.token_counts),
      total_co_occurrence_entries: encoder_state.co_occurrence
        |> Enum.map(fn {_t, n} -> map_size(n) end)
        |> Enum.sum(),
      traces_processed: encoder_state.traces_processed
    }}
  end

  def handle("kudzu_encoder_stats", _params) do
    {_codebook, encoder_state} = get_encoder_context()
    stats = EncoderState.stats(encoder_state)
    # Convert tuple lists to maps for JSON serialization
    json_safe = %{stats |
      top_tokens: Enum.map(stats.top_tokens, fn {token, count} ->
        %{token: token, count: count}
      end)
    }
    {:ok, json_safe}
  end

  # --- Private ---

  defp get_encoder_context do
    # Try to get from running consolidation daemon, fall back to fresh
    try do
      codebook = Consolidation.get_codebook()
      encoder_state = Consolidation.get_encoder_state()
      {codebook, encoder_state}
    rescue
      _ ->
        codebook = Encoder.init()
        encoder_state = EncoderState.load()
        {codebook, encoder_state}
    catch
      :exit, _ ->
        codebook = Encoder.init()
        encoder_state = EncoderState.load()
        {codebook, encoder_state}
    end
  end

  defp collect_all_traces(purpose_filter) do
    Application.list_holograms()
    |> Enum.flat_map(fn pid ->
      try do
        id = Hologram.get_id(pid)
        traces = Hologram.recall_all(pid)
        Enum.map(traces, fn trace -> {trace, id} end)
      rescue
        _ -> []
      end
    end)
    |> then(fn traces ->
      if purpose_filter do
        purpose_atom = try do
          String.to_existing_atom(purpose_filter)
        rescue
          _ -> nil
        end
        if purpose_atom do
          Enum.filter(traces, fn {trace, _id} -> trace.purpose == purpose_atom end)
        else
          traces
        end
      else
        traces
      end
    end)
  end

  defp extract_content_preview(hint) when is_map(hint) do
    content = Map.get(hint, :content) || Map.get(hint, "content") ||
              Map.get(hint, :summary) || Map.get(hint, "summary") ||
              Map.get(hint, :event) || Map.get(hint, "event")

    case content do
      nil -> inspect(hint) |> String.slice(0..120)
      text when is_binary(text) ->
        if String.length(text) > 120, do: String.slice(text, 0..117) <> "...", else: text
      other -> inspect(other) |> String.slice(0..120)
    end
  end

  defp extract_content_preview(_), do: ""
end
