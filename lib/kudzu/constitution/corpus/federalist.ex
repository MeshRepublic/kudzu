defmodule Kudzu.Constitution.Corpus.Federalist do
  @moduledoc """
  Parse the 85 Federalist Papers into paragraph-level chunks.

  Source: `priv/constitution/text/federalist/federalist_NN.txt` (NN
  zero-padded 01–85). One file per paper.

  Each chunk's `source_doc` is the corpus-level identifier
  ("The Federalist Papers"); `section_label` is the per-paper
  identifier ("Federalist N"); `paper_number` is the integer for
  per-paper filtering.

  Missing files are logged as warnings (Tier 5 distillation tolerates a
  few missing papers; calibration requires the full set).
  """

  require Logger

  alias Kudzu.Constitution.Corpus.Helpers

  @corpus_source_doc "The Federalist Papers"
  @source_doc_prefix "Federalist"
  @paper_numbers 1..85

  @type chunk :: %{
          text: String.t(),
          source_doc: String.t(),
          paper_number: 1..85,
          paragraph_offset: non_neg_integer(),
          section_label: String.t()
        }

  @doc """
  Stream chunks across all 85 papers in order. Lazily reads one file at a
  time via `Stream.flat_map/2`; safe for the 1.3MB corpus.
  """
  @spec stream_chunks() :: Enumerable.t()
  def stream_chunks do
    Stream.flat_map(@paper_numbers, &stream_one/1)
  end

  defp stream_one(n) do
    file = paper_path(n)

    case File.read(file) do
      {:ok, text} ->
        section_label = "#{@source_doc_prefix} #{n}"

        text
        |> String.replace("\r\n", "\n")
        |> Helpers.paragraph_chunks(section_label, @corpus_source_doc)
        |> Enum.map(&Map.put(&1, :paper_number, n))

      {:error, :enoent} ->
        Logger.warning("[Corpus.Federalist] missing source: #{file}")
        []
    end
  end

  defp paper_path(n) do
    Application.app_dir(
      :kudzu,
      "priv/constitution/text/federalist/federalist_#{pad(n)}.txt"
    )
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
