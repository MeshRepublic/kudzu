defmodule Kudzu.Brain.Vectors.WebLearnerVector do
  @moduledoc """
  Wraps the existing WebLearner to implement the DataVector behaviour.
  """

  @behaviour Kudzu.Brain.Vectors.Behaviour

  alias Kudzu.Brain.WebLearner

  @current_keywords ~w(latest newest 2024 2025 2026 release update news
    announcement version changelog)
  @web_keywords ~w(github npm pypi crate library framework package
    download install documentation api)

  @impl true
  def name, do: :web_learner

  @impl true
  def relevance(topic) do
    t = String.downcase(topic)
    score = 0.5

    # URLs are always best for web
    if Regex.match?(~r/https?:\/\//, t) do
      0.95
    else
      current = Enum.count(@current_keywords, &String.contains?(t, &1)) * 0.1
      web = Enum.count(@web_keywords, &String.contains?(t, &1)) * 0.08
      min(score + current + web, 1.0)
    end
  end

  @impl true
  def available? do
    case Kudzu.Brain.Tools.Web.execute("web_search", %{"query" => "test"}) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def learn(topic, opts \\ []) do
    case WebLearner.research(topic, opts) do
      {:ok, result} ->
        {:ok,
         %{
           content:
             "Web research on '#{topic}': #{result.pages_read} pages read, " <>
               "#{result.chains_stored} knowledge chains stored, " <>
               "#{Map.get(result, :summaries_stored, 0)} summaries saved",
           source: "web_search",
           confidence: 0.6,
           metadata: result
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
