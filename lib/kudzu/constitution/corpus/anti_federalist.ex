defmodule Kudzu.Constitution.Corpus.AntiFederalist do
  @moduledoc """
  Parse the four Anti-Federalist Letters series into paragraph-level
  chunks.

  Per spec decision #2, v0 scope is Letters series only (Brutus, Cato,
  Federal Farmer, Centinel). Yates/Lansing convention notes are
  excluded.

  Source: `priv/constitution/text/anti_federalist/{brutus,cato,
  federal_farmer,centinel}.txt`. Each file is one concatenated series.

  Each chunk's `source_doc` is the corpus-level identifier
  ("The Anti-Federalist Papers"); `section_label` is the per-series
  identifier ("Brutus Letters", "Cato Letters", etc.); `series` is the
  atom for series-specific filtering.
  """

  alias Kudzu.Constitution.Corpus.Helpers
  require Logger

  @corpus_source_doc "The Anti-Federalist Papers"

  @series_files [
    {:brutus, "brutus.txt", "Brutus Letters"},
    {:cato, "cato.txt", "Cato Letters"},
    {:federal_farmer, "federal_farmer.txt", "Letters from the Federal Farmer"},
    {:centinel, "centinel.txt", "Centinel Letters"}
  ]

  @type chunk :: %{
          text: String.t(),
          series: :brutus | :cato | :federal_farmer | :centinel,
          source_doc: String.t(),
          paragraph_offset: non_neg_integer(),
          section_label: String.t()
        }

  @doc """
  Stream chunks across all four series in declaration order.

  Missing files are logged and skipped (calibration requires the full
  set; distillation can tolerate gaps).
  """
  @spec stream_chunks() :: Enumerable.t()
  def stream_chunks do
    Stream.flat_map(@series_files, fn {series, fname, label} ->
      stream_one(series, fname, label)
    end)
  end

  defp stream_one(series, fname, label) do
    file = series_path(fname)

    case File.read(file) do
      {:ok, text} ->
        text
        |> String.replace("\r\n", "\n")
        |> Helpers.paragraph_chunks(label, @corpus_source_doc)
        |> Enum.map(&Map.put(&1, :series, series))

      {:error, :enoent} ->
        Logger.warning("[Corpus.AntiFederalist] missing source: #{file}")
        []
    end
  end

  defp series_path(fname) do
    Application.app_dir(:kudzu, "priv/constitution/text/anti_federalist/#{fname}")
  end
end
