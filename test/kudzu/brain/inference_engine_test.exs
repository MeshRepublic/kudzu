defmodule Kudzu.Brain.InferenceEngineTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.InferenceEngine
  alias Kudzu.Silo

  @test_domain "test_inference_#{:rand.uniform(999_999)}"

  setup_all do
    # Create silo once for all tests — avoids registry contention
    Silo.delete(@test_domain)
    Process.sleep(500)
    {:ok, _} = Silo.create(@test_domain)

    Silo.store_relationship(@test_domain, {"water", "causes", "erosion"})
    Silo.store_relationship(@test_domain, {"erosion", "creates", "canyons"})
    Silo.store_relationship(@test_domain, {"rain", "produces", "water"})

    on_exit(fn ->
      Silo.delete(@test_domain)
    end)

    %{domain: @test_domain}
  end

  describe "probe/2" do
    test "finds concepts related to a query", %{domain: domain} do
      results = InferenceEngine.probe(domain, "water")
      assert length(results) > 0
    end

    test "returns empty list for non-existent silo" do
      results = InferenceEngine.probe("nonexistent_inference_silo", "water")
      assert results == []
    end
  end

  describe "query_relationship/3" do
    test "retrieves stored relationships", %{domain: domain} do
      result = InferenceEngine.query_relationship(domain, "water", "causes")
      assert is_list(result)
      assert length(result) > 0
      # The top result should be the water-causes-erosion triple
      {top_match, _score} = hd(result)
      assert top_match.subject == "water"
      assert top_match.relation == "causes"
      assert top_match.object == "erosion"
    end

    test "returns results with similarity scores", %{domain: domain} do
      result = InferenceEngine.query_relationship(domain, "water", "causes")
      {_match, score} = hd(result)
      assert is_float(score)
      assert score > 0.0
    end

    test "returns at most 5 results", %{domain: domain} do
      result = InferenceEngine.query_relationship(domain, "water", "causes")
      assert length(result) <= 5
    end

    test "returns empty for non-existent silo" do
      result = InferenceEngine.query_relationship("nonexistent_inference_silo", "x", "y")
      assert result == []
    end
  end

  describe "cross_query/1" do
    test "searches all silos", %{domain: domain} do
      results = InferenceEngine.cross_query("water")
      assert is_list(results)
      # Should find results from our test silo
      assert Enum.any?(results, fn {d, _hint, _score} -> d == domain end)
    end

    test "results are sorted by score descending", %{domain: _domain} do
      results = InferenceEngine.cross_query("water")

      if length(results) > 1 do
        scores = Enum.map(results, fn {_d, _h, score} -> score end)
        assert scores == Enum.sort(scores, :desc)
      end
    end
  end

  describe "confidence/1" do
    test "classifies high scores" do
      assert InferenceEngine.confidence(0.8) == :high
      assert InferenceEngine.confidence(0.71) == :high
      assert InferenceEngine.confidence(0.95) == :high
    end

    test "classifies moderate scores" do
      assert InferenceEngine.confidence(0.5) == :moderate
      assert InferenceEngine.confidence(0.41) == :moderate
      assert InferenceEngine.confidence(0.7) == :moderate
    end

    test "classifies low scores" do
      assert InferenceEngine.confidence(0.2) == :low
      assert InferenceEngine.confidence(0.0) == :low
      assert InferenceEngine.confidence(0.4) == :low
    end
  end
end
