defmodule Kudzu.Embedding do
  @moduledoc """
  Ollama embedding client for semantic search.

  Generates 4096-dimensional vectors from llama3.1 via Ollama's /api/embed endpoint.
  All operations are free and local (no external API calls).

  ## Usage

      {:ok, vector} = Embedding.embed("Linux systemd manages services")
      {:ok, vectors} = Embedding.batch_embed(["text1", "text2"])
      score = Embedding.cosine_similarity(vec_a, vec_b)
  """

  require Logger

  @default_ollama_url "http://localhost:11434"
  @default_model "llama3.1"
  @timeout 30_000

  @doc """
  Embed a single text string. Returns a 4096-dimensional float vector.
  """
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    url = Keyword.get(opts, :ollama_url, @default_ollama_url)
    model = Keyword.get(opts, :model, @default_model)
    timeout = Keyword.get(opts, :timeout, @timeout)

    body = Jason.encode!(%{model: model, input: text})

    request = {
      ~c"#{url}/api/embed",
      [],
      ~c"application/json",
      body
    }

    case Kudzu.HTTP.request(:post, request, [{:timeout, timeout}]) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(to_string(response_body)) do
          {:ok, %{"embeddings" => [vector | _]}} ->
            {:ok, vector}

          {:ok, other} ->
            {:error, {:unexpected_response, other}}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http_error, status, to_string(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Embed multiple texts in a single API call.
  Returns vectors in the same order as input texts.
  """
  @spec batch_embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def batch_embed(texts, opts \\ []) when is_list(texts) do
    url = Keyword.get(opts, :ollama_url, @default_ollama_url)
    model = Keyword.get(opts, :model, @default_model)

    body = Jason.encode!(%{model: model, input: texts})

    request = {
      ~c"#{url}/api/embed",
      [],
      ~c"application/json",
      body
    }

    case Kudzu.HTTP.request(:post, request, [{:timeout, @timeout * 2}]) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(to_string(response_body)) do
          {:ok, %{"embeddings" => vectors}} when is_list(vectors) ->
            {:ok, vectors}

          {:ok, other} ->
            {:error, {:unexpected_response, other}}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http_error, status, to_string(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Compute cosine similarity between two vectors.
  Returns a float between -1.0 and 1.0.
  """
  @spec cosine_similarity([float()], [float()]) :: float()
  def cosine_similarity(vec_a, vec_b)
      when is_list(vec_a) and is_list(vec_b) and length(vec_a) == length(vec_b) do
    {dot, norm_a, norm_b} =
      Enum.zip(vec_a, vec_b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {a, b}, {dot, na, nb} ->
        {dot + a * b, na + a * a, nb + b * b}
      end)

    case {norm_a, norm_b} do
      {+0.0, _} -> 0.0
      {_, +0.0} -> 0.0
      _ -> dot / (:math.sqrt(norm_a) * :math.sqrt(norm_b))
    end
  end

  @doc """
  Check if the embedding service is available.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    url = Keyword.get(opts, :ollama_url, @default_ollama_url)

    case Kudzu.HTTP.request(:get, {~c"#{url}/api/tags", []}, [{:timeout, 5000}]) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  end
end
