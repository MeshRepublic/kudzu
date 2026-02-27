defmodule Kudzu.Brain.Thought do
  @moduledoc """
  The universal unit of reasoning. Ephemeral process.

  Spawned by the Monarch, activates concepts across silos via HRR similarity,
  chains reasoning, spawns sub-thoughts if needed, and reports back.
  Same shape at every depth — fractal self-similarity.
  """

  require Logger

  alias Kudzu.Brain.InferenceEngine

  @default_max_depth 3
  @default_max_breadth 5
  @default_timeout 5_000
  @activation_threshold 0.3

  defmodule Result do
    @moduledoc "The result of a thought process."
    defstruct [
      :id,
      :input,
      :depth,
      chain: [],
      activations: [],
      confidence: 0.0,
      resolution: nil,
      sub_results: []
    ]
  end

  @doc """
  Run a thought synchronously. Returns a Result.

  Options:
    - :monarch_pid — PID to report to (required for async, optional for sync)
    - :max_depth — max sub-thought nesting (default 3)
    - :max_breadth — max activations per step (default 5)
    - :timeout — ms before giving up (default 5000)
    - :depth — current depth in fractal (default 0)
    - :priming — list of concepts from working memory to bias activation
  """
  def run(input, opts \\ []) do
    id = generate_id()
    depth = Keyword.get(opts, :depth, 0)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_breadth = Keyword.get(opts, :max_breadth, @default_max_breadth)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    priming = Keyword.get(opts, :priming, [])

    task = Task.async(fn ->
      think(id, input, depth, max_depth, max_breadth, priming)
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil ->
        Logger.debug("[Thought #{id}] Timed out at depth #{depth}")
        %Result{id: id, input: input, depth: depth, resolution: :timeout}
    end
  end

  @doc """
  Run a thought asynchronously. Sends {:thought_result, id, Result} to monarch_pid.
  Returns {:ok, thought_id}.
  """
  def async_run(input, opts \\ []) do
    monarch_pid = Keyword.fetch!(opts, :monarch_pid)
    id = generate_id()

    Task.start(fn ->
      result = run(input, Keyword.put(opts, :depth, 0))
      result = %{result | id: id}
      send(monarch_pid, {:thought_result, id, result})
    end)

    {:ok, id}
  end

  defp think(id, input, depth, max_depth, max_breadth, priming) do
    activations = activate(input, priming, max_breadth)
    chain = build_chain(input, activations, depth, max_depth, max_breadth)
    confidence = evaluate_chain(chain)

    resolution = cond do
      confidence > 0.6 -> :found
      confidence > 0.3 -> :partial
      true -> :no_match
    end

    %Result{
      id: id,
      input: input,
      depth: depth,
      chain: chain,
      activations: activations,
      confidence: confidence,
      resolution: resolution
    }
  end

  defp activate(input, priming, max_breadth) do
    terms = extract_terms(input)

    (terms ++ priming)
    |> Enum.flat_map(fn term ->
      InferenceEngine.cross_query(term)
      |> Enum.map(fn {domain, hint, score} ->
        concept = extract_concept(hint)
        {concept, score, domain}
      end)
    end)
    |> Enum.uniq_by(fn {concept, _score, _domain} -> concept end)
    |> Enum.filter(fn {_concept, score, _domain} -> score >= @activation_threshold end)
    |> Enum.sort_by(fn {_concept, score, _domain} -> score end, :desc)
    |> Enum.take(max_breadth)
  end

  defp build_chain(input, activations, depth, max_depth, max_breadth) do
    initial = [%{concept: input, similarity: 1.0, source: "query"}]

    chain = Enum.reduce(activations, initial, fn {concept, score, domain}, chain ->
      chain ++ [%{concept: concept, similarity: score, source: domain}]
    end)

    if depth < max_depth and length(activations) > 0 do
      {top_concept, _score, _domain} = hd(activations)
      sub_result = run(top_concept,
        depth: depth + 1,
        max_depth: max_depth,
        max_breadth: max(max_breadth - 1, 2),
        timeout: 2_000
      )

      if sub_result.resolution in [:found, :partial] do
        sub_chain = sub_result.chain
        |> Enum.map(fn
          %{concept: _, similarity: _, source: _} = link -> link
          other -> %{concept: to_string(other), similarity: 0.0, source: "sub_thought"}
        end)
        chain ++ sub_chain
      else
        chain
      end
    else
      chain
    end
  end

  defp evaluate_chain(chain) do
    if length(chain) <= 1 do
      0.0
    else
      scores = chain
      |> Enum.map(fn
        %{similarity: score} -> score
        _ -> 0.0
      end)
      |> Enum.filter(& &1 > 0)

      if length(scores) == 0 do
        0.0
      else
        avg = Enum.sum(scores) / length(scores)
        length_bonus = min(length(scores) / 5.0, 0.2)
        min(avg + length_bonus, 1.0)
      end
    end
  end

  defp extract_terms(input) when is_binary(input) do
    input
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn term -> term in ~w(the a an is are was were be been being have has had do does did will would shall should may might can could what why how when where who which that this these those) end)
    |> Enum.uniq()
  end

  defp extract_terms(input), do: [to_string(input)]

  defp extract_concept(hint) when is_map(hint) do
    hint[:subject] || hint["subject"] || hint[:concept] || hint["concept"] || inspect(hint)
  end
  defp extract_concept(other), do: to_string(other)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
