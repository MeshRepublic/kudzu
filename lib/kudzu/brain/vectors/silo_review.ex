defmodule Kudzu.Brain.Vectors.SiloReview do
  @moduledoc """
  Reviews existing silo knowledge before going to external sources.
  Returns what Kudzu already knows about a topic.
  """

  @behaviour Kudzu.Brain.Vectors.Behaviour

  @impl true
  def name, do: :silo_review

  @impl true
  def relevance(topic) do
    results = Kudzu.Brain.InferenceEngine.cross_query(topic)
    case results do
      [{_, _, score} | _] when score > 0.3 -> 0.6
      _ -> 0.1
    end
  rescue
    _ -> 0.1
  end

  @impl true
  def available?, do: true

  @impl true
  def learn(topic, _opts \\ []) do
    results = Kudzu.Brain.InferenceEngine.cross_query(topic)
    relevant = Enum.filter(results, fn {_, _, score} -> score > 0.2 end)

    if relevant == [] do
      {:error, :no_existing_knowledge}
    else
      summary = Enum.map(relevant, fn {domain, hint, score} ->
        s = get_field(hint, :subject)
        r = get_field(hint, :relation)
        o = get_field(hint, :object)
        "- [#{domain}] #{s} #{r} #{o} (score: #{Float.round(score, 2)})"
      end) |> Enum.join("\n")

      {:ok, %{
        content: "Existing knowledge about '#{topic}':\n#{summary}",
        source: "silo_review",
        confidence: relevant |> Enum.map(&elem(&1, 2)) |> Enum.max(),
        metadata: %{domains: relevant |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}
      }}
    end
  end

  defp get_field(hint, key) when is_map(hint) do
    Map.get(hint, key, Map.get(hint, to_string(key), ""))
  end
  defp get_field(_, _), do: ""
end
