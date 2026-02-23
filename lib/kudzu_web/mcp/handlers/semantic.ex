defmodule KudzuWeb.MCP.Handlers.Semantic do
  @moduledoc """
  MCP handlers for semantic memory tools.

  Uses token-set similarity with contextual vector boosting for retrieval.
  Co-occurrence data from the HRR encoder improves results over time.
  """

  alias Kudzu.{Hologram, Application, HRR}
  alias Kudzu.HRR.{Encoder, EncoderState, Tokenizer}
  alias Kudzu.Consolidation

  def handle("kudzu_semantic_recall", params) do
    query = params["query"] || ""
    limit = Map.get(params, "limit", 10)
    purpose_filter = params["purpose"]
    threshold = Map.get(params, "threshold", 0.01)

    if query == "" do
      {:error, -32602, "Query text is required"}
    else
      {_codebook, encoder_state} = get_encoder_context()

      # Tokenize query into stemmed unigrams
      query_tokens = Tokenizer.unigrams(query) |> MapSet.new()

      if MapSet.size(query_tokens) == 0 do
        {:ok, %{query: query, results: [], count: 0, encoder_stats: encoder_summary(encoder_state)}}
      else
        # Precompute contextual vectors for query tokens
        query_vecs = query_tokens
        |> Enum.map(fn t -> {t, EncoderState.contextual_vector(encoder_state, t)} end)
        |> Map.new()

        # Collect and score all traces
        all_traces = collect_all_traces(purpose_filter)

        scored = all_traces
        |> Enum.map(fn {trace, hologram_id} ->
          hint = trace.reconstruction_hint || %{}
          trace_tokens = Tokenizer.tokenize_hint(hint)
            |> Enum.reject(&String.contains?(&1, "_"))
            |> MapSet.new()

          score = token_set_similarity(query_tokens, trace_tokens, query_vecs, encoder_state)
          {trace, hologram_id, score}
        end)
        |> Enum.filter(fn {_t, _h, score} -> score >= threshold end)
        |> Enum.sort_by(fn {_t, _h, score} -> score end, :desc)
        |> Enum.take(limit)

        results = Enum.map(scored, fn {trace, hologram_id, score} ->
          %{
            score: Float.round(score, 4),
            trace_id: trace.id,
            hologram_id: hologram_id,
            purpose: trace.purpose,
            content: extract_content_preview(trace.reconstruction_hint),
            reconstruction_hint: trace.reconstruction_hint
          }
        end)

        {:ok, %{
          query: query,
          query_tokens: MapSet.to_list(query_tokens),
          results: results,
          count: length(results),
          encoder_stats: encoder_summary(encoder_state)
        }}
      end
    end
  end

  def handle("kudzu_associations", params) do
    token = params["token"] || ""
    k = Map.get(params, "k", 10)

    if token == "" do
      {:error, -32602, "Token is required"}
    else
      {_codebook, encoder_state} = get_encoder_context()

      stemmed = Tokenizer.stem(String.downcase(token))
      neighbors = EncoderState.top_neighbors(encoder_state, stemmed, k: k)

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
    json_safe = %{stats |
      top_tokens: Enum.map(stats.top_tokens, fn {token, count} ->
        %{token: token, count: count}
      end)
    }
    {:ok, json_safe}
  end

  # --- Token-Set Similarity ---

  # Score = jaccard overlap + contextual boost from co-occurrence vectors
  defp token_set_similarity(query_tokens, trace_tokens, query_vecs, encoder_state) do
    shared = MapSet.intersection(query_tokens, trace_tokens)
    shared_count = MapSet.size(shared)

    if shared_count == 0 do
      # No direct overlap — check for co-occurrence proximity
      # For each query token, check if any trace token is a top neighbor
      indirect_score(query_tokens, trace_tokens, encoder_state)
    else
      union_count = MapSet.size(MapSet.union(query_tokens, trace_tokens))
      jaccard = shared_count / max(union_count, 1)

      # Contextual boost: average similarity between shared token vectors
      # and non-shared query token vectors (captures semantic proximity)
      boost = if shared_count < MapSet.size(query_tokens) do
        non_shared_query = MapSet.difference(query_tokens, shared)
        pairs = for s <- MapSet.to_list(shared),
                    q <- MapSet.to_list(non_shared_query) do
          sv = EncoderState.contextual_vector(encoder_state, s)
          qv = Map.get(query_vecs, q, EncoderState.base_vector(q, encoder_state.dim))
          HRR.similarity(sv, qv)
        end
        if pairs == [], do: 0.0, else: Enum.sum(pairs) / length(pairs)
      else
        0.0
      end

      jaccard + max(boost, 0.0) * 0.3
    end
  end

  # Indirect matching: no shared tokens, but check co-occurrence neighbors
  defp indirect_score(query_tokens, trace_tokens, encoder_state) do
    # For each query token, get its top co-occurrence neighbors
    # If any neighbor appears in the trace tokens, that's an indirect hit
    query_list = MapSet.to_list(query_tokens)

    hits = Enum.reduce(query_list, 0, fn qt, acc ->
      neighbors = EncoderState.top_neighbors(encoder_state, qt, k: 10)
      neighbor_tokens = Enum.map(neighbors, fn {t, _w} -> t end) |> MapSet.new()
      overlap = MapSet.intersection(neighbor_tokens, trace_tokens) |> MapSet.size()
      acc + overlap
    end)

    # Normalize by possible hits
    max_possible = MapSet.size(query_tokens) * 10
    if max_possible > 0, do: hits / max_possible * 0.15, else: 0.0
  end

  # --- Helpers ---

  defp encoder_summary(encoder_state) do
    %{
      vocabulary_size: map_size(encoder_state.token_counts),
      traces_processed: encoder_state.traces_processed,
      blend_strength: encoder_state.blend_strength
    }
  end

  defp get_encoder_context do
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
