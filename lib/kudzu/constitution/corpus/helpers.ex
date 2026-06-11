defmodule Kudzu.Constitution.Corpus.Helpers do
  @moduledoc """
  Shared chunking primitives for the corpus modules
  (`Corpus.Constitution`, `Corpus.Federalist`, `Corpus.AntiFederalist`).

  Provides paragraph-level chunking with provenance attachment so each
  corpus module only has to handle its source-specific section detection.
  """

  @type chunk :: %{
          text: String.t(),
          source_doc: String.t(),
          paragraph_offset: non_neg_integer(),
          section_label: String.t()
        }

  @doc """
  Split a body of text on blank lines into paragraphs, then yield each as
  a chunk with provenance.

  Empty / whitespace-only paragraphs are filtered. `paragraph_offset` is
  0-based within the body. Surrounding whitespace is trimmed from each
  paragraph.
  """
  @spec paragraph_chunks(String.t(), String.t(), String.t()) :: [chunk()]
  def paragraph_chunks(body, section_label, source_doc)
      when is_binary(body) and is_binary(section_label) and is_binary(source_doc) do
    body
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index()
    |> Enum.map(fn {text, idx} ->
      %{
        text: text,
        source_doc: source_doc,
        paragraph_offset: idx,
        section_label: section_label
      }
    end)
  end
end
