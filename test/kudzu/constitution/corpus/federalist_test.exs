defmodule Kudzu.Constitution.Corpus.FederalistTest do
  use ExUnit.Case, async: true

  alias Kudzu.Constitution.Corpus.Federalist

  describe "stream_chunks/0" do
    test "produces chunks from at least 80 papers (allows a few missing)" do
      chunks = Federalist.stream_chunks() |> Enum.to_list()
      papers_seen = chunks |> Enum.map(& &1.paper_number) |> Enum.uniq() |> length()
      assert papers_seen >= 80, "expected >= 80 papers, got #{papers_seen}"
    end

    test "every chunk carries paper_number, paragraph_offset, source_doc" do
      chunks = Federalist.stream_chunks() |> Enum.take(20)

      for chunk <- chunks do
        assert is_integer(chunk.paper_number)
        assert chunk.paper_number in 1..85
        assert is_integer(chunk.paragraph_offset)
        assert chunk.paragraph_offset >= 0
        assert chunk.source_doc =~ "Federalist"
        assert is_binary(chunk.text)
        assert byte_size(chunk.text) > 0
      end
    end

    test "section_label format is 'Federalist N'" do
      [first | _] = Federalist.stream_chunks() |> Enum.take(1)
      assert first.section_label =~ ~r/^Federalist \d+$/
    end
  end
end
