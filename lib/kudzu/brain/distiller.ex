defmodule Kudzu.Brain.Distiller do
  @moduledoc """
  Extracts Claude's reasoning into permanent knowledge.

  After any Claude (Tier 3) interaction, the Distiller:
  1. Extracts reasoning chains as relationship triples -> silo storage
  2. Identifies simple cause->action patterns -> reflex candidates
  3. Finds concepts not in any silo -> curiosity targets

  Uses pattern matching, not LLMs.
  """

  require Logger

  @relational_patterns [
    {~r/(.+?)\s+(?:is caused by|caused by|because of)\s+(.+)/i, "caused_by"},
    {~r/(.+?)\s+because\s+(.+)/i, "because"},
    {~r/(.+?)\s+(?:leads to|results in|causes)\s+(.+)/i, "causes"},
    {~r/(.+?)\s+requires?\s+(.+)/i, "requires"},
    {~r/(.+?)\s+uses?\s+(.+)/i, "uses"},
    {~r/(.+?)\s+(?:is a|is an)\s+(.+)/i, "is_a"},
    {~r/(.+?)\s+(?:consists of|contains|includes)\s+(.+)/i, "contains"},
    {~r/(.+?)\s+(?:relates to|connects to|depends on)\s+(.+)/i, "relates_to"},
    {~r/(.+?)\s+(?:produces?|generates?|creates?)\s+(.+)/i, "produces"},
    {~r/(.+?)\s+(?:provides?|enables?|supports?)\s+(.+)/i, "provides"}
  ]

  @stop_words ~w(the a an is are was were be been being have has had do does did will would shall should may might can could i you we they it this that these those my your our their its some any)

  # Relations scored higher are more meaningful/specific
  @relation_quality %{
    "caused_by" => 1.0,
    "causes" => 1.0,
    "requires" => 0.9,
    "because" => 0.85,
    "produces" => 0.8,
    "provides" => 0.75,
    "uses" => 0.7,
    "contains" => 0.65,
    "is_a" => 0.6,
    "relates_to" => 0.3
  }

  @prune_threshold 0.15
  @ollama_url "http://localhost:11434"
  @extract_model "llama4:scout"
  @extract_timeout 180_000

  @doc """
  Run the full distillation pipeline on text.

  Returns a map with:
  - `:chains` -- extracted relationship triples
  - `:reflex_candidates` -- cause-action pattern matches
  - `:knowledge_gaps` -- concepts not found in any silo
  """
  def distill(text, silo_domains, context \\ %{}) do
    if silo_domains == [] do
      # An empty silo_domains list is almost always a bug at the call site:
      # find_knowledge_gaps/2 has nothing to filter against, so every
      # token in `text` becomes a "gap." Historically two call sites
      # passed `[]` and the extracted chains were not even stored, so
      # the whole distillation was a no-op-with-log-spam. Warn loudly so
      # future regressions don't sneak back in silently.
      Logger.warning(
        "[Distiller] distill/3 called with empty silo_domains — caller is likely missing a silo list. " <>
          "Knowledge-gap detection will treat every token as novel."
      )
    end

    chains = extract_chains(text)
    reflex_candidates = extract_reflex_candidates(chains, context)
    knowledge_gaps = find_knowledge_gaps(text, silo_domains)
    %{chains: chains, reflex_candidates: reflex_candidates, knowledge_gaps: knowledge_gaps}
  end

  @doc """
  Extract causal/relational chains from text as {subject, relation, object} triples.

  When the `:kudzu, :distiller_use_claude` application env is true and an
  `ANTHROPIC_API_KEY` is set, the higher-quality Claude-backed
  `Kudzu.Silo.Extractor.extract_claude/3` is consulted first. The local
  Ollama path remains the default and is also used as fallback when the
  Claude call returns no triples or errors out.
  """
  def extract_chains(text) when is_binary(text) do
    if use_claude_extractor?() do
      case extract_with_claude(text) do
        {:ok, chains} when chains != [] ->
          Logger.debug("[Distiller] Claude extracted #{length(chains)} chains")
          chains

        other ->
          Logger.debug(
            "[Distiller] Claude extractor unavailable/empty (#{inspect(other) |> String.slice(0, 200)}), falling back to Ollama"
          )

          extract_chains_via_ollama(text)
      end
    else
      extract_chains_via_ollama(text)
    end
  end

  defp extract_chains_via_ollama(text) do
    ollama_result = try do
      extract_with_ollama(text)
    rescue
      e -> {:error, {:crashed, Exception.message(e)}}
    catch
      :exit, e -> {:error, {:exit, inspect(e) |> String.slice(0, 200)}}
    end

    case ollama_result do
      {:ok, chains} when chains != [] ->
        Logger.debug("[Distiller] Ollama extracted #{length(chains)} chains")
        chains

      other ->
        Logger.debug("[Distiller] Ollama fallback: #{inspect(other) |> String.slice(0, 200)}")
        text
        |> split_sentences()
        |> Enum.flat_map(&extract_from_sentence/1)
        |> Enum.uniq()
    end
  end

  defp use_claude_extractor? do
    Application.get_env(:kudzu, :distiller_use_claude, false) and
      is_binary(System.get_env("ANTHROPIC_API_KEY"))
  end

  defp extract_with_claude(text) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    try do
      case Kudzu.Silo.Extractor.extract_claude(text, api_key) do
        {:ok, triples} when is_list(triples) ->
          chains =
            triples
            |> Enum.map(&normalize_claude_triple/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          {:ok, chains}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, {:crashed, Exception.message(e)}}
    catch
      :exit, e -> {:error, {:exit, inspect(e) |> String.slice(0, 200)}}
    end
  end

  # Normalize Claude triples WITHOUT a relation whitelist. The 5-pages
  # experiment (`docs/superpowers/reviews/2026-06-09-5pages-experiment.md`)
  # showed the old 10-relation whitelist coerced 84.5%% of Claude's
  # natural relations to `relates_to`, destroying the signal Claude
  # produced. The prompt now does the constraining; this pass just
  # normalizes the relation string (lowercase, trimmed,
  # whitespace -> underscore) and drops empty relations.
  @doc false
  @spec normalize_claude_triple(term()) ::
          {String.t(), String.t(), String.t()} | nil
  def normalize_claude_triple({subject, relation, object}) do
    s = subject |> to_string() |> normalize_term()
    o = object |> to_string() |> normalize_term()
    r = normalize_relation(to_string(relation))

    cond do
      r == "" -> nil
      String.length(s) > 1 and String.length(o) > 1 -> {s, r, o}
      true -> nil
    end
  end

  def normalize_claude_triple(_), do: nil

  @doc false
  @spec normalize_relation(String.t()) :: String.t()
  def normalize_relation(rel) when is_binary(rel) do
    rel
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
  end

  @doc """
  Identify simple cause-action patterns from extracted chains.

  Given a list of chains and a context with `:available_actions`, finds
  chains where the cause/effect matches an available action.
  """
  def extract_reflex_candidates(chains, context) do
    available_actions = Map.get(context, :available_actions, [])

    chains
    |> Enum.filter(fn {_s, rel, _o} -> rel in ["caused_by", "because", "causes"] end)
    |> Enum.map(fn {subject, relation, object} ->
      action = find_matching_action(subject, object, relation, available_actions)

      if action do
        %{
          pattern: normalize_term(subject),
          condition: normalize_term(object),
          relation: relation,
          action: action
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Find concepts in text that are not covered by any known silo domain.

  Extracts meaningful terms from the text, filters out stop words and short
  words, then checks each against the provided silo domains and the
  InferenceEngine's cross_query.
  """
  def find_knowledge_gaps(text, silo_domains) do
    terms =
      text
      |> String.downcase()
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(fn term -> term in @stop_words end)
      |> Enum.reject(fn term -> String.length(term) < 3 end)
      |> Enum.frequencies()
      |> Enum.map(fn {term, _count} -> term end)

    silo_set = MapSet.new(silo_domains |> Enum.map(&String.downcase/1))

    terms
    |> Enum.reject(fn term -> MapSet.member?(silo_set, term) end)
    |> Enum.reject(fn term ->
      try do
        results = Kudzu.Brain.InferenceEngine.cross_query(term)
        Enum.any?(results, fn {_domain, _hint, score} -> score > 0.5 end)
      rescue
        _ -> false
      catch
        :exit, _ -> false
      end
    end)
  end

  @doc """
  Review all stored relationship triples across silos.

  1. Collects all relationship triples from all silos
  2. Merges redundant triples (same normalized subject/relation/object)
  3. Scores usefulness based on specificity and relation quality
  4. Prunes triples scoring below threshold

  Returns %{reviewed: count, merged: count, pruned: count}
  """
  def review_knowledge(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @prune_threshold)

    # Step 1: Collect all relationship triples from silos
    triples = collect_all_triples()
    total_count = length(triples)

    # Step 2: Merge redundant triples
    {merged_triples, merge_count} = merge_redundant(triples)

    # Step 3: Compute term frequencies for specificity scoring
    term_freqs = compute_term_frequencies(merged_triples)

    # Step 4: Score each triple
    scored = Enum.map(merged_triples, fn triple ->
      score = score_triple(triple, term_freqs)
      Map.put(triple, :score, score)
    end)

    # Step 5: Prune below threshold
    {keep, prune} = Enum.split_with(scored, fn t -> t.score >= threshold end)
    prune_count = length(prune)

    # Step 6: Actually delete pruned triples from their silos
    Enum.each(prune, fn triple ->
      delete_triple_from_silo(triple)
    end)

    Logger.info(
      "[Distiller] Knowledge review: #{total_count} reviewed, " <>
      "#{merge_count} merged, #{prune_count} pruned, #{length(keep)} kept"
    )

    %{reviewed: total_count, merged: merge_count, pruned: prune_count}
  end

  # --- Knowledge review helpers ---

  defp collect_all_triples do
    try do
      Kudzu.Silo.list()
      |> Enum.flat_map(fn {domain, pid, _id} ->
        try do
          state = :sys.get_state(pid)

          state.traces
          |> Map.values()
          |> Enum.filter(fn trace ->
            hint = trace.reconstruction_hint
            is_map(hint) and
              Map.get(hint, :type, Map.get(hint, "type")) == "relationship"
          end)
          |> Enum.map(fn trace ->
            hint = trace.reconstruction_hint
            %{
              subject: normalize_term(to_string(Map.get(hint, :subject, Map.get(hint, "subject", "")))),
              relation: to_string(Map.get(hint, :relation, Map.get(hint, "relation", "relates_to"))),
              object: normalize_term(to_string(Map.get(hint, :object, Map.get(hint, "object", "")))),
              domain: domain,
              trace_id: trace.id,
              silo_pid: pid
            }
          end)
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      end)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp merge_redundant(triples) do
    # Group by normalized {subject, relation, object}
    grouped =
      Enum.group_by(triples, fn t ->
        {t.subject, t.relation, t.object}
      end)

    merge_count =
      grouped
      |> Enum.map(fn {_key, group} -> length(group) - 1 end)
      |> Enum.sum()

    # Keep one representative from each group, delete the rest
    merged =
      Enum.map(grouped, fn {_key, [keeper | duplicates]} ->
        # Delete duplicate traces from their silos
        Enum.each(duplicates, fn dup ->
          delete_triple_from_silo(dup)
        end)

        keeper
      end)

    {merged, merge_count}
  end

  defp compute_term_frequencies(triples) do
    triples
    |> Enum.flat_map(fn t -> [t.subject, t.object] end)
    |> Enum.frequencies()
  end

  defp score_triple(triple, term_freqs) do
    # Relation quality score (0.0 - 1.0)
    rel_score = Map.get(@relation_quality, triple.relation, 0.5)

    # Specificity: inverse frequency of terms (rarer = more specific = higher score)
    max_freq = term_freqs |> Map.values() |> Enum.max(fn -> 1 end)
    subj_freq = Map.get(term_freqs, triple.subject, 1)
    obj_freq = Map.get(term_freqs, triple.object, 1)

    # Specificity ranges 0.0-1.0: terms appearing once get 1.0, most frequent gets ~0.1
    subj_spec = if max_freq > 1, do: 1.0 - (subj_freq - 1) / max_freq, else: 1.0
    obj_spec = if max_freq > 1, do: 1.0 - (obj_freq - 1) / max_freq, else: 1.0
    specificity = (subj_spec + obj_spec) / 2.0

    # Combined score: 60% relation quality, 40% specificity
    0.6 * rel_score + 0.4 * specificity
  end

  defp delete_triple_from_silo(triple) do
    try do
      pid = triple.silo_pid
      trace_id = triple.trace_id

      if Process.alive?(pid) do
        # Use the hologram's own delete_trace message instead of mutating
        # GenServer state externally via :sys.replace_state/2. The old
        # path was racy with in-flight handle_call/2's and bypassed the
        # hologram's message protocol entirely.
        Kudzu.Hologram.delete_trace(pid, trace_id)
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # --- Private helpers ---

  defp extract_with_ollama(text) do
    excerpt = if String.length(text) > 3000, do: String.slice(text, 0, 3000), else: text

    prompt = "Extract key factual relationships from this text. Return ONLY a JSON array of objects with \"subject\", \"relation\", and \"object\" fields.\n\nValid relations: caused_by, causes, requires, uses, is_a, contains, relates_to, produces, provides, because\n\nExample: [{\"subject\": \"Linux\", \"relation\": \"uses\", \"object\": \"systemd for init\"}]\n\nText:\n#{excerpt}\n\nJSON:"

    body = Jason.encode!(%{
      model: @extract_model,
      prompt: prompt,
      stream: false,
      options: %{num_predict: 1000, temperature: 0.1},
      keep_alive: "10m"
    })

    request = {~c"#{@ollama_url}/api/generate", [], ~c"application/json", body}

    case Kudzu.HTTP.request(:post, request, [{:timeout, @extract_timeout}]) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(to_string(response_body)) do
          {:ok, %{"response" => response}} ->
            Logger.debug("[Distiller] Ollama response (first 200): #{String.slice(response, 0, 500)}")
            {:ok, parse_json_triples(response)}
          _ ->
            {:error, :parse_failed}
        end

      {:ok, {{_, status, _}, _, err_body}} ->
        Logger.warning("[Distiller] Ollama HTTP #{status}: #{String.slice(to_string(err_body), 0, 200)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[Distiller] Ollama request failed: #{inspect(reason)}")
        {:error, :ollama_unavailable}
    end
  end

  defp parse_json_triples(response) do
    # Try multiple strategies to find JSON array in response
    json_str = find_json_array(response)

    case json_str do
      nil ->
        Logger.debug("[Distiller] No JSON array found in response")
        []

      str ->
        case Jason.decode(str) do
          {:ok, items} when is_list(items) ->
            items
            |> Enum.map(fn item when is_map(item) ->
              subject = Map.get(item, "subject", "") |> to_string() |> normalize_term()
              relation = Map.get(item, "relation", "relates_to") |> to_string()
              object = Map.get(item, "object", "") |> to_string() |> normalize_term()

              relation = if relation in ~w(caused_by causes requires uses is_a contains relates_to produces provides because) do
                relation
              else
                "relates_to"
              end

              if String.length(subject) > 1 and String.length(object) > 1 do
                {subject, relation, object}
              end
            _ -> nil
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          {:error, reason} ->
            Logger.debug("[Distiller] JSON decode failed: #{inspect(reason)}")
            []

          _ ->
            []
        end
    end
  end

  defp find_json_array(text) do
    trimmed = String.trim(text)

    # Strategy 1: Direct JSON decode (response is just a JSON array)
    case Jason.decode(trimmed) do
      {:ok, items} when is_list(items) -> trimmed
      _ ->
        # Strategy 2: Extract from markdown code fences
        case Regex.run(~r//, trimmed) do
          [_, inner] ->
            inner = String.trim(inner)
            case Jason.decode(inner) do
              {:ok, _} -> inner
              _ -> find_json_array_bare(trimmed)
            end
          _ ->
            find_json_array_bare(trimmed)
        end
    end
  end

  defp find_json_array_bare(text) do
    # Strategy 3: Find [ ... ] containing at least one {
    case Regex.run(~r/\[\s*\{[\s\S]*?\}\s*\]/, text) do
      [match] -> match
      _ -> nil
    end
  end

  defp split_sentences(text) do
    text
    |> String.split(~r/[.!?\n]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn s -> String.length(s) < 5 end)
  end

  defp extract_from_sentence(sentence) do
    @relational_patterns
    |> Enum.flat_map(fn {regex, relation} ->
      case Regex.run(regex, sentence, capture: :all_but_first) do
        [subject, object] ->
          s = normalize_term(subject)
          o = normalize_term(object)

          if String.length(s) > 1 and String.length(o) > 1 do
            [{s, relation, o}]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp normalize_term(term) do
    safe = case :unicode.characters_to_binary(to_string(term)) do
      {:error, valid, _} -> valid
      {:incomplete, valid, _} -> valid
      binary when is_binary(binary) -> binary
    end

    safe
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/[^\w_]/, "")
  end

  defp find_matching_action(subject, object, _relation, available_actions) do
    terms = [normalize_term(subject), normalize_term(object)]

    Enum.find(available_actions, fn action ->
      action_str = to_string(action) |> String.downcase()

      Enum.any?(terms, fn term ->
        String.contains?(action_str, term) or String.contains?(term, action_str)
      end)
    end)
  end
end
