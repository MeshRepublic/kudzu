defmodule Kudzu.Silo.Relationship do
  @moduledoc """
  Encodes subject-relation-object triples as HRR bindings.

  Each triple (S, R, O) is encoded as: bind(S, bind(R, O))
  where S, R, O are deterministically seeded HRR vectors.
  """

  alias Kudzu.HRR

  @concept_prefix "concept_v1_"
  @relation_prefix "relation_v1_"

  @doc """
  Encode a {subject, relation, object} triple as an HRR vector.
  """
  @spec encode({String.t(), String.t(), String.t()}) :: HRR.vector()
  def encode({subject, relation, object}) do
    dim = HRR.default_dim()
    s = HRR.seeded_vector("#{@concept_prefix}#{normalize(subject)}", dim)
    r = HRR.seeded_vector("#{@relation_prefix}#{normalize(relation)}", dim)
    o = HRR.seeded_vector("#{@concept_prefix}#{normalize(object)}", dim)
    HRR.bind(s, HRR.bind(r, o))
  end

  @doc "Generate a deterministic concept vector for a term."
  @spec concept_vector(String.t(), pos_integer()) :: HRR.vector()
  def concept_vector(term, dim \\ HRR.default_dim()),
    do: HRR.seeded_vector("#{@concept_prefix}#{normalize(term)}", dim)

  @doc "Generate a deterministic relation vector for a relation type."
  @spec relation_vector(String.t(), pos_integer()) :: HRR.vector()
  def relation_vector(rel, dim \\ HRR.default_dim()),
    do: HRR.seeded_vector("#{@relation_prefix}#{normalize(rel)}", dim)

  defp normalize(term), do: term |> to_string() |> String.downcase()
end
