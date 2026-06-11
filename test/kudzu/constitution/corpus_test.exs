defmodule Kudzu.Constitution.CorpusTest do
  use ExUnit.Case, async: true

  alias Kudzu.Constitution.Corpus

  describe "stream_chunks/0" do
    test "merges Constitution + Federalist + AntiFederalist streams" do
      chunks = Corpus.stream_chunks() |> Enum.to_list()
      sources = chunks |> Enum.map(& &1.source_doc) |> Enum.uniq() |> Enum.sort()

      assert "U.S. Constitution" in sources
      assert "The Federalist Papers" in sources
      assert "The Anti-Federalist Papers" in sources
    end

    test "every chunk has the canonical shape" do
      for chunk <- Corpus.stream_chunks() |> Enum.take(50) do
        assert Map.has_key?(chunk, :text)
        assert Map.has_key?(chunk, :source_doc)
        assert Map.has_key?(chunk, :paragraph_offset)
        assert Map.has_key?(chunk, :section_label)
      end
    end

    test "filters out markdown-header-only chunks (Task 8 carry-forward)" do
      # The 4 AntiFederalist files start with "# <Series> Letters" headers.
      # The orchestrator's filter should strip them so downstream sees only
      # real paragraph content.
      all_chunks = Corpus.stream_chunks() |> Enum.to_list()

      header_only =
        Enum.filter(all_chunks, fn c ->
          Regex.match?(~r/^#+\s+\w+\s+Letters\s*$/, c.text)
        end)

      assert Enum.empty?(header_only),
             "expected no markdown-header-only chunks; got #{length(header_only)}"
    end
  end

  describe "stream_chunks/1 with limits" do
    test "honors :per_source limits for testing" do
      chunks = Corpus.stream_chunks(per_source: 3) |> Enum.to_list()
      grouped = Enum.group_by(chunks, & &1.source_doc)

      for {_doc, doc_chunks} <- grouped do
        assert length(doc_chunks) <= 3
      end
    end
  end
end
