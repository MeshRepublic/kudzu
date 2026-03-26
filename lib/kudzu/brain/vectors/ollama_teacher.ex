defmodule Kudzu.Brain.Vectors.OllamaTeacher do
  @moduledoc """
  Asks the local LLM to teach about topics. Completely free and local.

  Three modes:
  - :explain — thorough explanation with examples
  - :list — enumerate key concepts/components
  - :compare — compare and contrast aspects
  """

  @behaviour Kudzu.Brain.Vectors.Behaviour

  require Logger

  @model "llama4:scout"
  @timeout 180_000

  @conceptual_keywords ~w(explain what why how concept theory principle
    algorithm pattern design architecture philosophy history meaning
    difference between compare overview introduction basics fundamentals
    advanced guide tutorial learn understand)

  @programming_keywords ~w(programming language function class module
    data structure recursion concurrency parallel distributed type
    compiler interpreter runtime memory stack heap garbage collection
    elixir erlang otp python rust go java javascript)

  @current_keywords ~w(latest newest 2024 2025 2026 release update
    announcement news today yesterday recent)

  @system_keywords ~w(command terminal bash shell linux man page
    systemctl apt install package)

  @impl true
  def name, do: :ollama_teacher

  @impl true
  def relevance(topic) do
    t = String.downcase(topic)
    score = 0.5

    conceptual = Enum.count(@conceptual_keywords, &String.contains?(t, &1)) * 0.08
    programming = Enum.count(@programming_keywords, &String.contains?(t, &1)) * 0.06
    current_penalty = Enum.count(@current_keywords, &String.contains?(t, &1)) * -0.15
    system_penalty = Enum.count(@system_keywords, &String.contains?(t, &1)) * -0.05

    (score + conceptual + programming + current_penalty + system_penalty)
    |> max(0.0)
    |> min(1.0)
  end

  @impl true
  def available? do
    url = get_ollama_url()
    case Kudzu.HTTP.request(:get, {~c"#{url}/api/tags", []}, [{:timeout, 5_000}]) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def learn(topic, opts \\ []) do
    mode = Keyword.get(opts, :mode, :explain)
    prompt = build_prompt(topic, mode)

    case call_ollama(prompt) do
      {:ok, response} when byte_size(response) > 50 ->
        {:ok, %{
          content: response,
          source: "ollama:#{@model}",
          confidence: 0.7,
          metadata: %{mode: mode, model: @model}
        }}

      {:ok, _short} ->
        {:error, :response_too_short}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_prompt(topic, :explain) do
    """
    You are an expert teacher. Explain the following topic thoroughly but concisely.
    Include key concepts, how they relate to each other, practical examples,
    and common pitfalls. Structure your response with clear sections.

    Topic: #{topic}
    """
  end

  defp build_prompt(topic, :list) do
    """
    List the key concepts, components, and subtopics of: #{topic}

    For each item, provide a brief 1-2 sentence description.
    Include at least 10 items, ordered from foundational to advanced.
    Format each as: "- Concept: Description"
    """
  end

  defp build_prompt(topic, :compare) do
    """
    Compare and contrast the key aspects of: #{topic}

    For each aspect, note similarities and differences.
    Include practical implications of each difference.
    """
  end

  defp call_ollama(prompt) do
    url = get_ollama_url()

    body = Jason.encode!(%{
      model: @model,
      prompt: prompt,
      stream: false,
      options: %{num_predict: 2000, temperature: 0.4},
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

  defp get_ollama_url do
    Application.get_env(:kudzu, :ollama_url, "http://localhost:11434")
  end
end
