defmodule Kudzu.Constitution.Corpus do
  @moduledoc """
  Orchestrator that merges Constitution + Federalist + Anti-Federalist
  streams. Each chunk carries `:text, :source_doc, :paragraph_offset,
  :section_label` plus source-specific fields (e.g. `:paper_number` on
  Federalist chunks, `:series` on Anti-Federalist chunks).

  Order: Constitution first (foundational text), then Federalist Papers
  (1–85 in order), then Anti-Federalist Letters. This is the order
  distillation sees, which can matter for incremental builds
  (Constitution distills fastest; if cost-capped, the most critical
  triples land first).

  Applies a noise filter that drops chunks containing only markdown
  headers (e.g., "# Brutus Letters") since those are page-level titles,
  not constitutional argument.
  """

  alias Kudzu.Constitution.Corpus.{AntiFederalist, Constitution, Federalist}

  @type chunk :: %{
          required(:text) => String.t(),
          required(:source_doc) => String.t(),
          required(:paragraph_offset) => non_neg_integer(),
          required(:section_label) => String.t(),
          optional(:paper_number) => 1..85,
          optional(:series) => atom()
        }

  @doc "Stream every chunk in canonical order, with noise filtering."
  @spec stream_chunks() :: Enumerable.t()
  def stream_chunks, do: stream_chunks([])

  @doc """
  Stream chunks with optional limits.

  Options:
    * `:per_source` — integer, takes at most N chunks per source_doc
      (useful for testing and budget-capped runs).
  """
  @spec stream_chunks(keyword()) :: Enumerable.t()
  def stream_chunks(opts) do
    raw =
      Stream.concat([
        Constitution.stream_chunks(),
        Federalist.stream_chunks(),
        AntiFederalist.stream_chunks()
      ])

    filtered = Stream.reject(raw, &header_only?/1)

    case Keyword.get(opts, :per_source) do
      nil -> filtered
      n when is_integer(n) and n > 0 -> per_source_limit(filtered, n)
    end
  end

  # Drops chunks that are short markdown-header lines (e.g., "# Brutus Letters").
  # Pattern: starts with one or more #, followed by whitespace, then word chars,
  # short enough to plausibly be a title (< 100 bytes).
  defp header_only?(chunk) do
    byte_size(chunk.text) < 100 and Regex.match?(~r/^#+\s+\S/, chunk.text)
  end

  defp per_source_limit(stream, n) do
    Stream.transform(stream, %{}, fn chunk, counts ->
      count = Map.get(counts, chunk.source_doc, 0)

      if count < n do
        {[chunk], Map.put(counts, chunk.source_doc, count + 1)}
      else
        {[], counts}
      end
    end)
  end
end
