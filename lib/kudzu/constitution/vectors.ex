defmodule Kudzu.Constitution.Vectors do
  @moduledoc """
  The one vector basis for constitutional comparison.

  Stages 1–3 of `Kudzu.Constitution.Distilled` compare a proposal vector
  against silo triples. Those two vectors are only comparable if they are
  produced by the same encoder over the same basis, so **every** vector
  that enters that comparison — proposal text, AGI-loop thoughts, and the
  silo triples themselves — must come from this module.

  ## Encoding

  Text is tokenized with `Kudzu.HRR.Tokenizer` (lower-cased, stop words
  dropped, raw + stemmed unigrams and adjacent-stem bigrams). Each token
  maps to a deterministic HRR vector seeded in a namespace private to this
  module; the text vector is the normalized bundle (sum) of its token
  vectors. A triple `{subject, relation, object}` is encoded as the text
  `"subject relation object"`.

  Cosine similarity between two encodings therefore approximates their
  normalized token overlap, `|A ∩ B| / sqrt(|A| · |B|)`, plus noise of
  order `1/sqrt(dim)` from near-orthogonal token vectors. "criminalizing
  speech critical of the government" lands near the rejection triple
  "historical_act retards criminalization of speech critical of the
  government"; an unrelated proposal does not.

  This is lexical, not semantic, similarity: paraphrases that share no
  vocabulary will not match. That is a known limitation of a
  self-contained basis; the AI Judge (Stage 4) covers what the vector
  stages miss.

  ## Why silo vectors are computed, not read

  Silo traces also carry a stored `:vector` (`Kudzu.Silo.Relationship`
  binding, used by `Kudzu.Silo.probe/2`). That vector lives in a
  different basis and must not be compared with proposal vectors. Stages
  1–3 re-encode each triple here instead, so they can never drift apart
  from the proposal encoder — including across HRR backend changes.
  """

  alias Kudzu.HRR
  alias Kudzu.HRR.Tokenizer

  @namespace "constitution_token_v1_"

  @doc """
  Encode free text. Returns `nil` when the text has no content tokens.
  """
  @spec encode_text(String.t()) :: HRR.vector() | nil
  def encode_text(text) when is_binary(text) do
    case Tokenizer.tokenize(text) do
      [] -> nil
      tokens -> tokens |> Enum.map(&token_vector/1) |> HRR.bundle()
    end
  end

  def encode_text(_), do: nil

  @doc "Encode a `{subject, relation, object}` triple in the same basis."
  @spec encode_triple({String.t(), String.t(), String.t()}) :: HRR.vector() | nil
  def encode_triple({subject, relation, object}),
    do: encode_text(Enum.join([subject, relation, object], " "))

  @doc """
  Encode the triple held in a silo trace hint (atom or string keys).
  Returns `nil` when the hint is not a triple.
  """
  @spec encode_hint(map()) :: HRR.vector() | nil
  def encode_hint(hint) when is_map(hint) do
    with s when is_binary(s) <- field(hint, :subject),
         r when is_binary(r) <- field(hint, :relation),
         o when is_binary(o) <- field(hint, :object) do
      encode_triple({s, r, o})
    else
      _ -> nil
    end
  end

  def encode_hint(_), do: nil

  defp token_vector(token), do: HRR.seeded_vector(@namespace <> token, HRR.default_dim())

  defp field(hint, key), do: Map.get(hint, key, Map.get(hint, Atom.to_string(key)))
end
