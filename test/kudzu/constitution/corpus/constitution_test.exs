defmodule Kudzu.Constitution.Corpus.ConstitutionTest do
  use ExUnit.Case, async: true

  alias Kudzu.Constitution.Corpus.Constitution

  describe "stream_chunks/0" do
    test "produces non-empty chunks with provenance" do
      chunks = Constitution.stream_chunks() |> Enum.take(5)
      assert length(chunks) == 5

      for chunk <- chunks do
        assert is_binary(chunk.text)
        assert byte_size(chunk.text) > 0
        assert chunk.source_doc == "U.S. Constitution"
        assert is_integer(chunk.paragraph_offset)
        assert chunk.paragraph_offset >= 0
        assert is_binary(chunk.section_label)
      end
    end

    test "preamble is the first chunk" do
      [first | _] = Constitution.stream_chunks() |> Enum.take(1)
      assert String.contains?(String.downcase(first.text), "we the people")
      assert first.section_label =~ ~r/preamble/i
    end

    test "chunks include amendments" do
      chunks = Constitution.stream_chunks() |> Enum.to_list()

      first_amendment_chunks =
        Enum.filter(chunks, fn c ->
          String.contains?(c.section_label, "Amendment I") or
            String.contains?(c.section_label, "Amendment 1")
        end)

      refute Enum.empty?(first_amendment_chunks),
             "expected at least one chunk tagged for Amendment I"
    end
  end
end
