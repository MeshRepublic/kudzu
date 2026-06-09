defmodule Kudzu.Brain.Vectors.Router do
  @moduledoc """
  Routes learning topics to the best data vector.

  Scores all available vectors for a topic, then tries them in order
  of relevance. Falls through to the next vector on failure.
  """

  require Logger

  alias Kudzu.Brain.Vectors.{
    OllamaTeacher,
    WebLearnerVector,
    SystemIntrospector,
    LocalDocReader,
    SiloReview
  }

  @vectors [
    OllamaTeacher,
    WebLearnerVector,
    SystemIntrospector,
    LocalDocReader,
    SiloReview
  ]

  @relevance_threshold 0.3

  @doc """
  Learn about a topic using the best available vector.
  Falls through vectors on failure.
  """
  @spec learn(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def learn(topic, opts \\ []) do
    ranked =
      rank_vectors(topic)
      |> Enum.filter(fn {_mod, score} -> score >= @relevance_threshold end)
      |> Enum.filter(fn {mod, _score} ->
        try do
          mod.available?()
        rescue
          _ -> false
        end
      end)

    case try_vectors(ranked, topic, opts) do
      {:ok, result} ->
        Logger.info("[VectorRouter] Learned '#{String.slice(topic, 0, 60)}' via #{result.vector}")
        {:ok, result}

      {:error, reason} ->
        Logger.warning(
          "[VectorRouter] All vectors failed for '#{String.slice(topic, 0, 60)}': #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Score all vectors for a topic. Returns sorted list.
  """
  @spec rank_vectors(String.t()) :: [{module(), float()}]
  def rank_vectors(topic) do
    @vectors
    |> Enum.map(fn mod ->
      score =
        try do
          mod.relevance(topic)
        rescue
          _ -> 0.0
        end

      {mod, score}
    end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
  end

  @doc """
  List all registered vectors with availability status.
  """
  @spec list_vectors() :: [map()]
  def list_vectors do
    Enum.map(@vectors, fn mod ->
      %{
        name: mod.name(),
        available:
          try do
            mod.available?()
          rescue
            _ -> false
          end,
        module: mod
      }
    end)
  end

  defp try_vectors([], _topic, _opts), do: {:error, :all_vectors_failed}

  defp try_vectors([{mod, score} | rest], topic, opts) do
    Logger.debug(
      "[VectorRouter] Trying #{mod.name()} (score=#{Float.round(score, 2)}) for: #{String.slice(topic, 0, 80)}"
    )

    case mod.learn(topic, opts) do
      {:ok, result} ->
        {:ok, Map.put(result, :vector, mod.name())}

      {:error, reason} ->
        Logger.debug("[VectorRouter] #{mod.name()} failed: #{inspect(reason)}, trying next")
        try_vectors(rest, topic, opts)
    end
  catch
    kind, reason ->
      Logger.warning("[VectorRouter] #{mod.name()} crashed: #{inspect(kind)}: #{inspect(reason)}")
      try_vectors(rest, topic, opts)
  end
end
