defmodule Kudzu.Brain.CurriculumGenerator do
  @moduledoc """
  Generates learning curricula using the local Ollama LLM.

  Replaces the Claude API-based curriculum generation with a free,
  local alternative using llama4:scout.
  """

  require Logger

  @model "llama4:scout"
  @timeout 180_000

  @prompt """
  You are building a learning curriculum. Generate a structured list of topics
  someone must master to become an expert in: %TOPIC%

  Return ONLY a valid JSON array of strings, ordered from foundational to advanced.
  Include 30-80 topics depending on domain breadth (30 for narrow topics, up to 80
  for broad domains). Each topic should be specific enough to research in a single
  web search session.

  Example format:
  ["Topic one", "Topic two", "Topic three"]
  """

  @doc """
  Generate a learning curriculum for the given topic.

  Returns `{:ok, items}` where items is a list of topic strings.
  """
  @spec generate(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def generate(topic) do
    prompt = String.replace(@prompt, "%TOPIC%", topic)

    case call_ollama(prompt) do
      {:ok, response} ->
        parse_curriculum_json(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_ollama(prompt) do
    url = get_ollama_url()

    body = Jason.encode!(%{
      model: @model,
      prompt: prompt,
      stream: false,
      options: %{num_predict: 4000, temperature: 0.3},
      keep_alive: "10m"
    })

    request = {~c"#{url}/api/generate", [], ~c"application/json", body}

    case Kudzu.HTTP.request(:post, request, [{:timeout, @timeout}]) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(to_string(response_body)) do
          {:ok, %{"response" => text}} -> {:ok, text}
          _ -> {:error, :parse_failed}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_curriculum_json(text) do
    cleaned = text
    |> String.replace(~r/```json\s*/m, "")
    |> String.replace(~r/```\s*/m, "")
    |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, items} when is_list(items) ->
        items = items
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

        if length(items) > 0, do: {:ok, items}, else: {:error, :empty}

      {:ok, _} ->
        {:error, :not_a_list}

      {:error, _} ->
        # Try to extract JSON array from response
        case Regex.run(~r/\[[\s\S]*\]/, cleaned) do
          [json_str] ->
            case Jason.decode(json_str) do
              {:ok, items} when is_list(items) ->
                items = items |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
                if length(items) > 0, do: {:ok, items}, else: {:error, :empty}
              _ ->
                {:error, :json_parse_failed}
            end
          nil ->
            {:error, :json_parse_failed}
        end
    end
  end

  defp get_ollama_url do
    Application.get_env(:kudzu, :ollama_url, "http://localhost:11434")
  end
end
