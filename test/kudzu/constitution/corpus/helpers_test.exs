defmodule Kudzu.Constitution.Corpus.HelpersTest do
  use ExUnit.Case, async: true

  alias Kudzu.Constitution.Corpus.Helpers

  describe "paragraph_chunks/3" do
    test "splits body on blank lines and attaches provenance" do
      body = "First paragraph.\n\nSecond paragraph.\n\nThird."
      chunks = Helpers.paragraph_chunks(body, "Test Section", "Test Doc")

      assert length(chunks) == 3

      assert Enum.at(chunks, 0) == %{
               text: "First paragraph.",
               paragraph_offset: 0,
               section_label: "Test Section",
               source_doc: "Test Doc"
             }

      assert Enum.at(chunks, 1).paragraph_offset == 1
      assert Enum.at(chunks, 2).paragraph_offset == 2
    end

    test "filters empty paragraphs" do
      body = "Real paragraph.\n\n\n\n\n\nAnother real."
      chunks = Helpers.paragraph_chunks(body, "S", "D")
      assert length(chunks) == 2
    end

    test "trims surrounding whitespace from paragraphs" do
      body = "   leading and trailing   \n\n   normal text   "
      chunks = Helpers.paragraph_chunks(body, "S", "D")
      assert Enum.at(chunks, 0).text == "leading and trailing"
      assert Enum.at(chunks, 1).text == "normal text"
    end

    test "handles a single-paragraph body" do
      body = "Just one paragraph."
      chunks = Helpers.paragraph_chunks(body, "S", "D")
      assert length(chunks) == 1
      assert Enum.at(chunks, 0).text == "Just one paragraph."
      assert Enum.at(chunks, 0).paragraph_offset == 0
    end

    test "handles an empty body" do
      chunks = Helpers.paragraph_chunks("", "S", "D")
      assert chunks == []
    end
  end
end
