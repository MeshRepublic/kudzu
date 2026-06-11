defmodule Kudzu.Constitution.Corpus.AntiFederalistTest do
  use ExUnit.Case, async: true

  alias Kudzu.Constitution.Corpus.AntiFederalist

  describe "stream_chunks/0" do
    test "produces chunks from each of the four series" do
      chunks = AntiFederalist.stream_chunks() |> Enum.to_list()
      series_seen = chunks |> Enum.map(& &1.series) |> Enum.uniq() |> Enum.sort()
      assert series_seen == [:brutus, :cato, :centinel, :federal_farmer]
    end

    test "every chunk carries series, paragraph_offset, section_label, source_doc" do
      chunks = AntiFederalist.stream_chunks() |> Enum.take(20)

      for chunk <- chunks do
        assert chunk.series in [:brutus, :cato, :centinel, :federal_farmer]
        assert is_integer(chunk.paragraph_offset)
        assert chunk.paragraph_offset >= 0
        assert is_binary(chunk.source_doc)
        assert is_binary(chunk.section_label)
        assert is_binary(chunk.text)
        assert byte_size(chunk.text) > 0
      end
    end

    test "all chunks share source_doc 'The Anti-Federalist Papers'" do
      chunks = AntiFederalist.stream_chunks() |> Enum.take(50)
      unique_sources = chunks |> Enum.map(& &1.source_doc) |> Enum.uniq()
      assert unique_sources == ["The Anti-Federalist Papers"]
    end
  end
end
