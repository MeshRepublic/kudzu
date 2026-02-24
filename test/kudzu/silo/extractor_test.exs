defmodule Kudzu.Silo.ExtractorTest do
  use ExUnit.Case, async: true

  alias Kudzu.Silo.Extractor

  describe "extract_patterns/1" do
    test "finds simple is/causes/requires patterns" do
      text = "Water causes erosion. Erosion requires time. Gravity is fundamental."
      triples = Extractor.extract_patterns(text)

      assert {"Water", "causes", "erosion"} in triples
      assert {"Erosion", "requires", "time"} in triples
      assert {"Gravity", "is", "fundamental"} in triples
      assert length(triples) == 3
    end

    test "returns empty for no matches" do
      triples = Extractor.extract_patterns("Hello world.")
      assert triples == []
    end

    test "handles multi-word subjects and objects" do
      text = "The consolidation daemon uses tiered storage."
      triples = Extractor.extract_patterns(text)
      assert length(triples) == 1
      assert {"The consolidation daemon", "uses", "tiered storage"} in triples
    end

    test "handles uses/provides/contains patterns" do
      text = "The server provides fast responses. The list contains many items."
      triples = Extractor.extract_patterns(text)
      assert length(triples) == 2
      assert {"The server", "provides", "fast responses"} in triples
      assert {"The list", "contains", "many items"} in triples
    end

    test "splits on semicolons and newlines" do
      text = "Elixir uses BEAM; BEAM provides concurrency\nOTP requires Erlang"
      triples = Extractor.extract_patterns(text)
      assert length(triples) == 3
    end

    test "handles cause without trailing s" do
      text = "Bugs cause failures."
      triples = Extractor.extract_patterns(text)
      assert {"Bugs", "causes", "failures"} in triples
    end

    test "handles singular verb forms (require, use, provide, contain)" do
      text = "The system require authentication."
      triples = Extractor.extract_patterns(text)
      assert length(triples) == 1
    end

    test "is case insensitive" do
      text = "Water IS important."
      triples = Extractor.extract_patterns(text)
      assert length(triples) == 1
    end
  end

  describe "parse_extraction_response/1" do
    test "parses valid JSON triples" do
      json = ~s([["water","causes","erosion"],["gravity","attracts","mass"]])
      assert {:ok, triples} = Extractor.parse_extraction_response(json)
      assert length(triples) == 2
      assert {"water", "causes", "erosion"} in triples
      assert {"gravity", "attracts", "mass"} in triples
    end

    test "handles no JSON in response" do
      assert {:error, :no_json_found} = Extractor.parse_extraction_response("no json here")
    end

    test "handles invalid JSON" do
      assert {:error, :invalid_json} = Extractor.parse_extraction_response("[not valid json]")
    end

    test "filters out non-triple arrays" do
      json = ~s([["a","b","c"],["too","few"],["a","b","c","too_many"]])
      assert {:ok, triples} = Extractor.parse_extraction_response(json)
      assert length(triples) == 1
      assert {"a", "b", "c"} in triples
    end

    test "downcases all terms" do
      json = ~s([["Water","Causes","Erosion"]])
      assert {:ok, [{"water", "causes", "erosion"}]} =
               Extractor.parse_extraction_response(json)
    end

    test "handles JSON embedded in surrounding text" do
      text = ~s(Here are the triples: [["elixir","uses","beam"]] That's all.)
      assert {:ok, [{"elixir", "uses", "beam"}]} =
               Extractor.parse_extraction_response(text)
    end
  end
end
