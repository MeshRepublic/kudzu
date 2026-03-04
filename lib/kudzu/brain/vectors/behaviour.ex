defmodule Kudzu.Brain.Vectors.Behaviour do
  @moduledoc """
  Behaviour for data vectors — pluggable knowledge sources.

  Each vector can score its relevance for a topic, then fetch/generate
  knowledge about that topic. The VectorRouter uses these to pick the
  best source for any given learning task.
  """

  @type topic :: String.t()
  @type learn_result :: {:ok, %{
    content: String.t(),
    source: String.t(),
    confidence: float(),
    metadata: map()
  }} | {:error, term()}

  @callback name() :: atom()
  @callback relevance(topic()) :: float()
  @callback learn(topic(), keyword()) :: learn_result()
  @callback available?() :: boolean()
end
