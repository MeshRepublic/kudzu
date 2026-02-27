defmodule Kudzu.Brain.Distiller do
  @moduledoc """
  Extracts Claude's reasoning into permanent knowledge.

  After any Claude (Tier 3) interaction, the Distiller:
  1. Extracts reasoning chains as relationship triples -> silo storage
  2. Identifies simple cause->action patterns -> reflex candidates
  3. Finds concepts not in any silo -> curiosity targets

  Uses pattern matching, not LLMs.
  """

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

  @doc """
  Run the full distillation pipeline on text.

  Returns a map with:
  - `:chains` -- extracted relationship triples
  - `:reflex_candidates` -- cause-action pattern matches
  - `:knowledge_gaps` -- concepts not found in any silo
  """
  def distill(text, silo_domains, context \\ %{}) do
    chains = extract_chains(text)
    reflex_candidates = extract_reflex_candidates(chains, context)
    knowledge_gaps = find_knowledge_gaps(text, silo_domains)
    %{chains: chains, reflex_candidates: reflex_candidates, knowledge_gaps: knowledge_gaps}
  end

  @doc """
  Extract causal/relational chains from text as {subject, relation, object} triples.
  """
  def extract_chains(text) when is_binary(text) do
    text
    |> split_sentences()
    |> Enum.flat_map(&extract_from_sentence/1)
    |> Enum.uniq()
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

  # --- Private helpers ---

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
    term
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
