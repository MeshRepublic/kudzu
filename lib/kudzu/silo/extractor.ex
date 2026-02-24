defmodule Kudzu.Silo.Extractor do
  @moduledoc """
  Extracts subject-relation-object triples from text.
  Two modes: pattern-based (free) and Claude-assisted (costs tokens).
  """
  require Logger

  alias Kudzu.Brain.Claude

  # === Pattern-Based Extraction (free) ===

  # Patterns as {regex, relation_name} — no anonymous functions so they
  # can live in a module attribute (Elixir can't escape funs at compile time).
  @patterns [
    {~r/^(\w[\w\s]*\w)\s+is\s+(\w[\w\s]*\w)$/i, "is"},
    {~r/^(\w[\w\s]*\w)\s+causes?\s+(\w[\w\s]*\w)$/i, "causes"},
    {~r/^(\w[\w\s]*\w)\s+requires?\s+(\w[\w\s]*\w)$/i, "requires"},
    {~r/^(\w[\w\s]*\w)\s+uses?\s+(\w[\w\s]*\w)$/i, "uses"},
    {~r/^(\w[\w\s]*\w)\s+provides?\s+(\w[\w\s]*\w)$/i, "provides"},
    {~r/^(\w[\w\s]*\w)\s+contains?\s+(\w[\w\s]*\w)$/i, "contains"}
  ]

  @doc "Extract triples using pattern matching (free, no LLM)"
  @spec extract_patterns(String.t()) :: list({String.t(), String.t(), String.t()})
  def extract_patterns(text) when is_binary(text) do
    text
    |> String.split(~r/[.;!\n]/)
    |> Enum.flat_map(fn sentence ->
      sentence = String.trim(sentence)

      Enum.flat_map(@patterns, fn {regex, relation} ->
        case Regex.run(regex, sentence, capture: :all_but_first) do
          nil ->
            []

          [subject, object] ->
            [{String.trim(subject), relation, String.trim(object)}]

          _ ->
            []
        end
      end)
    end)
  end

  # === Claude-Assisted Extraction (costs tokens) ===

  @extraction_prompt """
  Extract subject-relation-object triples from the following text.
  Return ONLY a JSON array of triples, each as [subject, relation, object].
  Use lowercase, concise terms. Common relations: is, causes, requires, uses,
  provides, contains, enables, prevents, relates_to, part_of, has_property.

  Example input: "The holographic principle states that information in a volume
  can be encoded on its boundary surface."
  Example output: [["holographic_principle","states","volume_info_on_boundary"],
  ["volume_information","encoded_on","boundary_surface"]]

  Text to extract from:
  """

  @doc "Extract triples using Claude API (costs tokens, higher quality)"
  @spec extract_claude(String.t(), String.t(), keyword()) ::
          {:ok, list({String.t(), String.t(), String.t()})} | {:error, term()}
  def extract_claude(text, api_key, opts \\ []) do
    model = Keyword.get(opts, :model, "claude-sonnet-4-6")
    message = @extraction_prompt <> text

    case Claude.call(api_key, [%{role: "user", content: message}], [],
           model: model,
           max_tokens: 1024
         ) do
      {:ok, response} ->
        parse_extraction_response(response.text)

      {:error, reason} ->
        Logger.error("[Extractor] Claude extraction failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  @spec parse_extraction_response(String.t()) ::
          {:ok, list({String.t(), String.t(), String.t()})} | {:error, atom()}
  def parse_extraction_response(text) do
    # Find JSON array in response
    case Regex.run(~r/\[.*\]/s, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, triples} when is_list(triples) ->
            result =
              triples
              |> Enum.filter(fn t -> is_list(t) and length(t) == 3 end)
              |> Enum.map(fn [s, r, o] ->
                {String.downcase(to_string(s)),
                 String.downcase(to_string(r)),
                 String.downcase(to_string(o))}
              end)

            {:ok, result}

          _ ->
            {:error, :invalid_json}
        end

      nil ->
        {:error, :no_json_found}
    end
  end
end
