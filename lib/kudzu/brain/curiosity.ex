defmodule Kudzu.Brain.Curiosity do
  @moduledoc """
  Generates questions when no one is asking.

  Three sources:
  1. Desire-driven — desires imply knowledge gaps
  2. Gap-driven — working memory dead ends become questions
  3. Salience-driven — unexplored high-salience traces

  Enhanced with `generate_research_questions/4` for web-search-effective
  question generation with deduplication and rephrasing.
  """

  alias Kudzu.Brain.WorkingMemory

  @max_questions 5
  @max_research_questions 3

  @desire_themes %{
    "health" => [
      "What is the current system health status?",
      "What failures have occurred recently?",
      "What recovery actions are available?"
    ],
    "self-model" => [
      "What components make up my architecture?",
      "What are my resource limits?",
      "What capabilities do I have?"
    ],
    "learn" => [
      "What patterns have I observed recently?",
      "What recurring events should I understand better?",
      "What knowledge domains am I weakest in?"
    ],
    "fault tolerance" => [
      "How can I recover from failures automatically?",
      "What single points of failure exist?",
      "What redundancy do I have?"
    ],
    "knowledge gaps" => [
      "What concepts have I encountered but don't understand?",
      "What domains have no expertise silo yet?",
      "What questions have I failed to answer?"
    ]
  }

  # Maps silo domain names to searchable keywords for rephrasing
  @domain_keywords %{
    "erlang" => "Erlang OTP",
    "elixir" => "Elixir language",
    "beam" => "BEAM virtual machine",
    "otp" => "Erlang OTP",
    "distributed" => "distributed systems",
    "networking" => "network protocols",
    "linux" => "Linux system administration",
    "health" => "system health monitoring",
    "fault_tolerance" => "fault tolerance recovery",
    "patterns" => "software design patterns",
    "learning" => "machine learning patterns",
    "self" => "self-monitoring autonomous systems",
    "security" => "system security hardening",
    "storage" => "data storage persistence",
    "web" => "web technologies"
  }

  # Question word prefixes to strip during rephrasing
  @question_prefixes [
    "what is the ",
    "what is ",
    "what are the ",
    "what are ",
    "what does ",
    "what do ",
    "how does ",
    "how do ",
    "how can i ",
    "how can ",
    "how should i ",
    "how should ",
    "how to ",
    "why is the ",
    "why is ",
    "why are ",
    "why does ",
    "why do ",
    "where is ",
    "where are ",
    "when does ",
    "when do ",
    "which ",
    "can i ",
    "can ",
    "should i ",
    "should "
  ]

  @doc """
  Generate up to 5 raw curiosity questions from desires, gaps, and salience.
  """
  def generate(desires, %WorkingMemory{} = wm, silo_domains) do
    desire_qs = generate_from_desires(desires, silo_domains)
    gap_qs = generate_from_gaps(wm)
    salience_qs = generate_from_salience(@max_questions)

    (gap_qs ++ desire_qs ++ salience_qs)
    |> Enum.uniq()
    |> Enum.take(@max_questions)
  end

  @doc """
  Enhanced question generation for web research.

  Takes an additional `researched_topics` MapSet to avoid repeating research.
  Returns up to 3 questions rephrased for web search effectiveness.

  ## Parameters
    - `desires` - list of desire strings
    - `wm` - WorkingMemory struct
    - `silo_domains` - list of silo domain name strings
    - `researched_topics` - MapSet of already-researched normalized topic strings
  """
  def generate_research_questions(
        desires,
        %WorkingMemory{} = wm,
        silo_domains,
        %MapSet{} = researched_topics
      ) do
    desires
    |> generate(wm, silo_domains)
    |> filter_researched(researched_topics)
    |> Enum.map(&rephrase_for_search(&1, silo_domains))
    |> Enum.uniq()
    |> Enum.take(@max_research_questions)
  end

  @doc """
  Normalize a topic string for deduplication.
  Downcases, strips punctuation, and trims whitespace.
  """
  def normalize_topic(topic) do
    topic
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  @doc """
  Rephrase a question into a web-search-effective query.

  Strips question words, removes trailing question marks, and enriches
  with contextual keywords based on active silo domains.
  """
  def rephrase_for_search(question, silo_domains) do
    question
    |> strip_question_form()
    |> enrich_with_domain_keywords(silo_domains)
    |> String.trim()
  end

  @doc "Filter out questions that have already been explored (by Jaro distance)."
  def filter_explored(questions, explored_set) when is_list(questions) do
    Enum.reject(questions, fn q ->
      normalized = String.downcase(String.trim(q))

      MapSet.member?(explored_set, normalized) or
        Enum.any?(explored_set, fn explored ->
          String.jaro_distance(normalized, explored) > 0.85
        end)
    end)
  end

  def filter_explored(questions, _), do: questions

  # --- Existing generators (unchanged) ---

  def generate_from_desires(desires, silo_domains) do
    desires
    |> Enum.flat_map(fn desire ->
      theme = classify_desire(desire)
      templates = Map.get(@desire_themes, theme, [])

      if has_silo_coverage?(theme, silo_domains) do
        templates |> Enum.drop(1) |> Enum.take(1)
      else
        Enum.take(templates, 1)
      end
    end)
    |> Enum.uniq()
  end

  def generate_from_gaps(%WorkingMemory{recent_chains: chains}) do
    chains
    |> Enum.flat_map(fn chain ->
      chain
      |> Enum.filter(fn
        %{similarity: score} when score < 0.2 -> true
        %{source: "dead_end"} -> true
        _ -> false
      end)
      |> Enum.map(fn
        %{concept: concept} -> "What is #{concept}?"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq()
  end

  def generate_from_salience(limit) do
    try do
      state = Kudzu.Consolidation.stats()

      if state[:traces_processed] && state[:traces_processed] > 0 do
        Kudzu.Consolidation.semantic_query("important unresolved", 0.3)
        |> Enum.take(limit)
        |> Enum.map(fn {purpose, _score} -> "What does #{purpose} tell me?" end)
      else
        []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  # --- Private helpers ---

  defp filter_researched(questions, researched_topics) do
    Enum.reject(questions, fn q ->
      normalized = normalize_topic(q)
      MapSet.member?(researched_topics, normalized)
    end)
  end

  defp strip_question_form(question) do
    # Remove trailing question mark
    stripped = String.replace(question, ~r/\?\s*$/, "")

    # Remove leading question words (case-insensitive)
    lower = String.downcase(stripped)

    prefix_match =
      @question_prefixes
      |> Enum.find(fn prefix -> String.starts_with?(lower, prefix) end)

    case prefix_match do
      nil ->
        stripped

      prefix ->
        # Remove the prefix, preserving original casing of the remainder
        prefix_len = String.length(prefix)
        String.slice(stripped, prefix_len..-1//1)
    end
  end

  defp enrich_with_domain_keywords(query, silo_domains) do
    # Find relevant domain keywords that are not already in the query
    query_lower = String.downcase(query)

    relevant_keywords =
      silo_domains
      |> Enum.map(fn domain ->
        domain_lower = String.downcase(domain)
        Map.get(@domain_keywords, domain_lower)
      end)
      |> Enum.reject(fn kw ->
        is_nil(kw) or String.contains?(query_lower, String.downcase(kw))
      end)
      # Only add the single most relevant keyword to keep queries focused
      |> Enum.take(1)

    case relevant_keywords do
      [] -> query
      [keyword] -> "#{query} #{keyword}"
    end
  end

  defp classify_desire(desire) do
    desire_lower = String.downcase(desire)

    cond do
      String.contains?(desire_lower, "health") or String.contains?(desire_lower, "recover") ->
        "health"

      String.contains?(desire_lower, "self-model") or
          String.contains?(desire_lower, "architecture") ->
        "self-model"

      String.contains?(desire_lower, "learn") or String.contains?(desire_lower, "pattern") ->
        "learn"

      String.contains?(desire_lower, "fault") or String.contains?(desire_lower, "distributed") ->
        "fault tolerance"

      true ->
        "knowledge gaps"
    end
  end

  defp has_silo_coverage?(theme, silo_domains) do
    domain_set = MapSet.new(silo_domains |> Enum.map(&String.downcase/1))

    case theme do
      "health" -> MapSet.member?(domain_set, "health")
      "self-model" -> MapSet.member?(domain_set, "self")
      "learn" -> MapSet.member?(domain_set, "learning") or MapSet.member?(domain_set, "patterns")
      "fault tolerance" -> MapSet.member?(domain_set, "fault_tolerance")
      _ -> false
    end
  end
end
