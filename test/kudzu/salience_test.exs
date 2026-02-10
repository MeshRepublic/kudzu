defmodule Kudzu.SalienceTest do
  use ExUnit.Case, async: true

  alias Kudzu.Salience

  describe "new/1" do
    test "creates salience with default values" do
      salience = Salience.new()

      assert salience.novelty == 1.0
      assert salience.access_count == 0
      assert salience.importance == :normal
      assert salience.consolidation_count == 0
      assert salience.recency != nil
      assert salience.created_at != nil
    end

    test "creates salience with custom importance" do
      salience = Salience.new(importance: :critical)
      assert salience.importance == :critical
    end

    test "creates salience with custom novelty" do
      salience = Salience.new(novelty: 0.5)
      assert salience.novelty == 0.5
    end
  end

  describe "score/1" do
    test "returns a value between 0 and 1" do
      salience = Salience.new()
      score = Salience.score(salience)

      assert score >= 0.0
      assert score <= 1.0
    end

    test "critical importance increases score" do
      normal = Salience.new(importance: :normal)
      critical = Salience.new(importance: :critical)

      assert Salience.score(critical) > Salience.score(normal)
    end

    test "trivial importance decreases score" do
      normal = Salience.new(importance: :normal)
      trivial = Salience.new(importance: :trivial)

      assert Salience.score(trivial) < Salience.score(normal)
    end
  end

  describe "on_access/1" do
    test "increments access count" do
      salience = Salience.new()
      updated = Salience.on_access(salience)

      assert updated.access_count == 1
    end

    test "updates recency" do
      salience = Salience.new()
      # Force old recency
      old_salience = %{salience | recency: DateTime.add(DateTime.utc_now(), -3600, :second)}
      updated = Salience.on_access(old_salience)

      assert DateTime.compare(updated.recency, old_salience.recency) == :gt
    end

    test "slightly boosts novelty (reconsolidation effect)" do
      salience = %{Salience.new() | novelty: 0.5}
      updated = Salience.on_access(salience)

      assert updated.novelty > 0.5
    end
  end

  describe "on_consolidation/1" do
    test "increments consolidation count" do
      salience = Salience.new()
      updated = Salience.on_consolidation(salience)

      assert updated.consolidation_count == 1
    end

    test "sets last_consolidated timestamp" do
      salience = Salience.new()
      updated = Salience.on_consolidation(salience)

      assert updated.last_consolidated != nil
    end

    test "decays novelty" do
      salience = Salience.new()
      updated = Salience.on_consolidation(salience)

      assert updated.novelty < salience.novelty
    end
  end

  describe "strengthen_associations/2" do
    test "increases associative strength" do
      salience = Salience.new()
      updated = Salience.strengthen_associations(salience, 0.2)

      assert updated.associative_strength == 0.2
    end

    test "caps at 1.0" do
      salience = %{Salience.new() | associative_strength: 0.95}
      updated = Salience.strengthen_associations(salience, 0.2)

      assert updated.associative_strength == 1.0
    end
  end

  describe "set_emotional_valence/2" do
    test "sets positive valence" do
      salience = Salience.new()
      updated = Salience.set_emotional_valence(salience, 0.8)

      assert updated.emotional_valence == 0.8
    end

    test "sets negative valence" do
      salience = Salience.new()
      updated = Salience.set_emotional_valence(salience, -0.5)

      assert updated.emotional_valence == -0.5
    end

    test "clamps to [-1, 1]" do
      salience = Salience.new()
      updated = Salience.set_emotional_valence(salience, 2.0)

      assert updated.emotional_valence == 1.0
    end
  end

  describe "consolidation_candidate?/2" do
    test "new traces are not candidates" do
      salience = Salience.new()
      refute Salience.consolidation_candidate?(salience, min_age_hours: 1)
    end

    test "low score traces are not candidates" do
      salience = %{Salience.new() |
        created_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        novelty: 0.01
      }
      refute Salience.consolidation_candidate?(salience, min_score: 0.5)
    end
  end

  describe "archival_candidate?/2" do
    test "critical importance traces are never archived" do
      salience = %{Salience.new() |
        importance: :critical,
        created_at: DateTime.add(DateTime.utc_now(), -172800, :second),
        consolidation_count: 5,
        novelty: 0.01
      }
      refute Salience.archival_candidate?(salience)
    end

    test "unconsolidated traces are not archived" do
      salience = %{Salience.new() |
        created_at: DateTime.add(DateTime.utc_now(), -172800, :second),
        consolidation_count: 0
      }
      refute Salience.archival_candidate?(salience)
    end
  end

  describe "serialization" do
    test "to_map/1 and from_map/1 roundtrip" do
      original = Salience.new(importance: :high, novelty: 0.7)
      |> Salience.on_access()
      |> Salience.strengthen_associations(0.3)

      map = Salience.to_map(original)
      restored = Salience.from_map(map)

      assert restored.novelty == original.novelty
      assert restored.access_count == original.access_count
      assert restored.importance == original.importance
      assert restored.associative_strength == original.associative_strength
    end
  end
end
