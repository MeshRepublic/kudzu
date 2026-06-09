defmodule Kudzu.Contradiction do
  @moduledoc """
  Detects contradictions between new traces and existing knowledge.
  Uses embedding similarity to find related traces, then checks for
  negation indicators that suggest conflicting information.
  """

  alias Kudzu.{Embedding, Storage}
  require Logger

  @similarity_threshold 0.7
  @contradiction_indicators [
    "not",
    "never",
    "instead",
    "wrong",
    "incorrect",
    "actually",
    "contrary",
    "opposite",
    "false",
    "no longer",
    "deprecated",
    "removed",
    "replaced",
    "changed from",
    "used to"
  ]

  @doc """
  Check if new content contradicts existing traces.
  Returns {:ok, :no_contradiction} or {:contradiction, details_map}.
  """
  def check(new_content, opts \\ []) when is_binary(new_content) do
    threshold = Keyword.get(opts, :threshold, @similarity_threshold)

    case Embedding.embed(new_content, timeout: 15_000) do
      {:ok, new_vector} ->
        results = Storage.search_by_embedding(new_vector, limit: 5, threshold: threshold)
        check_results(new_content, results)

      {:error, _} ->
        {:ok, :no_contradiction}
    end
  rescue
    _ -> {:ok, :no_contradiction}
  end

  defp check_results(_new_content, []), do: {:ok, :no_contradiction}

  defp check_results(new_content, results) do
    new_lower = String.downcase(new_content)
    has_negation = Enum.any?(@contradiction_indicators, &String.contains?(new_lower, &1))

    contradictions =
      Enum.filter(results, fn %{record: record, similarity: sim} ->
        existing_content = extract_text(record)
        existing_lower = String.downcase(existing_content)

        sim > @similarity_threshold and has_negation and
          content_opposes?(new_lower, existing_lower)
      end)

    case contradictions do
      [] ->
        {:ok, :no_contradiction}

      [first | _] ->
        {:contradiction,
         %{
           existing_content: extract_text(first.record),
           new_content: new_content,
           similarity: first.similarity,
           existing_trace_id: first.trace_id
         }}
    end
  end

  defp content_opposes?(new, existing) do
    new_words = String.split(new) |> MapSet.new()
    existing_words = String.split(existing) |> MapSet.new()
    overlap = MapSet.intersection(new_words, existing_words) |> MapSet.size()
    total = min(MapSet.size(new_words), MapSet.size(existing_words))
    total > 0 and overlap / total > 0.3
  end

  defp extract_text(%{reconstruction_hint: hint}) when is_map(hint) do
    Map.get(hint, :content, Map.get(hint, "content", ""))
  end

  defp extract_text(_), do: ""
end
