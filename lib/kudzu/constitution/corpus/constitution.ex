defmodule Kudzu.Constitution.Corpus.Constitution do
  @moduledoc """
  Parse the U.S. Constitution + Amendments into chunks with paragraph-
  level provenance.

  Chunking strategy: each Article section and each Amendment becomes a
  section; the body of every section is split on blank lines into
  paragraphs, and each paragraph emerges as one chunk. The
  `:paragraph_offset` field tracks ¶ position within the section so a
  downstream consumer can recover the exact location of a fact.

  Output rows: `%{text, source_doc, paragraph_offset, section_label}`.

  Source: `priv/constitution/text/constitution/constitution.txt`,
  assembled from three National Archives pages — the main body
  ("Article. I.", "Article. II.", ...), the Bill of Rights
  ("Amendment I" through "Amendment X" with mixed case), and Amendments
  XI through XXVII (with upper-case "AMENDMENT"). The section detector
  handles all three styles.
  """

  alias Kudzu.Constitution.Corpus.Helpers

  @source_doc "U.S. Constitution"

  # Heading patterns. Each captures the roman numeral when relevant.
  #
  # Article headings on the National Archives page use "Article. I." with
  # trailing dot; some mirrors drop the dot. Match both.
  @article_re ~r/^Article\.?\s+([IVX]+)\.?\s*$/
  # Bill of Rights amendments use mixed case "Amendment I".
  @amendment_lower_re ~r/^Amendment\s+([IVX]+)\s*$/
  # Amendments XI-XXVII use all-caps "AMENDMENT XI".
  @amendment_upper_re ~r/^AMENDMENT\s+([IVX]+)\s*$/

  @type chunk :: %{
          text: String.t(),
          source_doc: String.t(),
          paragraph_offset: non_neg_integer(),
          section_label: String.t()
        }

  @doc """
  Stream paragraph-level chunks from the Constitution source file.

  Returns an `Enumerable.t/0` of `t:chunk/0` maps in document order:
  Preamble first, then Article I..VII (with their internal Sections
  collapsed into the Article body), then Amendment I..XXVII.
  """
  @spec stream_chunks() :: Enumerable.t()
  def stream_chunks do
    source_file()
    |> File.read!()
    |> String.replace("\r\n", "\n")
    |> split_into_sections()
    |> Enum.flat_map(fn {label, body} ->
      Helpers.paragraph_chunks(body, label, @source_doc)
    end)
  end

  defp source_file do
    Application.app_dir(
      :kudzu,
      "priv/constitution/text/constitution/constitution.txt"
    )
  end

  # Walk the file line by line. Maintain (current_label, current_body, acc).
  # When we see a heading line, flush the current section to acc and start a
  # new one. The synthetic "Preamble" label covers everything before the first
  # Article heading.
  defp split_into_sections(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({"Preamble", [], []}, fn line, {label, buf, acc} ->
      case heading_label(line) do
        nil ->
          {label, [line | buf], acc}

        new_label ->
          {new_label, [], [{label, finalize_body(buf)} | acc]}
      end
    end)
    |> finalize_walk()
  end

  defp finalize_walk({label, buf, acc}) do
    [{label, finalize_body(buf)} | acc]
    |> Enum.reverse()
    |> Enum.reject(fn {_label, body} -> body == "" end)
  end

  defp finalize_body(buf) do
    buf
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  # Returns the canonical section label for a heading line, or nil.
  defp heading_label(line) do
    trimmed = String.trim(line)

    cond do
      m = Regex.run(@article_re, trimmed) -> "Article " <> Enum.at(m, 1)
      m = Regex.run(@amendment_lower_re, trimmed) -> "Amendment " <> Enum.at(m, 1)
      m = Regex.run(@amendment_upper_re, trimmed) -> "Amendment " <> Enum.at(m, 1)
      true -> nil
    end
  end
end
