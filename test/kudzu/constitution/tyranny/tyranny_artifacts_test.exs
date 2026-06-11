defmodule Kudzu.Constitution.Tyranny.TyrannyArtifactsTest do
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.Tyranny.TyrannyArtifacts

  setup do
    salt = :rand.uniform(99_999)
    rejection = "rejection:us_constitution_mesh_artifacts_test_#{salt}"
    {:ok, _} = Kudzu.Silo.create(rejection, %{})
    %{rejection: rejection}
  end

  describe "import_all/1" do
    test "reads tyranny.yaml and writes one trace per entry", %{rejection: r} do
      count = TyrannyArtifacts.import_all(rejection_silo: r)
      assert count >= 30

      traces = Kudzu.Silo.list_traces(r)
      assert length(traces) >= 30

      sample = List.first(traces)
      assert sample.reconstruction_hint.origin_type == :tyranny_artifact
      assert Map.has_key?(sample.reconstruction_hint, :citation)
      assert Map.has_key?(sample.reconstruction_hint, :principle)
      assert Map.has_key?(sample.reconstruction_hint, :vector)
    end

    test "is idempotent — running twice does not duplicate entries", %{rejection: r} do
      _ = TyrannyArtifacts.import_all(rejection_silo: r)
      first_count = length(Kudzu.Silo.list_traces(r))

      _ = TyrannyArtifacts.import_all(rejection_silo: r)
      second_count = length(Kudzu.Silo.list_traces(r))

      assert first_count == second_count
    end
  end

  describe "validate_manifest/1" do
    test "rejects entry missing required fields" do
      {:error, errors} = TyrannyArtifacts.validate_manifest([%{"name" => "X"}])
      assert Enum.any?(errors, &(&1 =~ "missing"))
    end

    test "accepts a complete entry" do
      entry = %{
        "name" => "X",
        "year" => 1800,
        "citation" => "X v. Y",
        "description" => "test description",
        "principle_violated" => "free_speech",
        "source_url" => "https://example.com"
      }

      assert {:ok, _} = TyrannyArtifacts.validate_manifest([entry])
    end
  end
end
