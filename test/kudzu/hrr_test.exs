defmodule Kudzu.HRRTest do
  use ExUnit.Case, async: true

  alias Kudzu.HRR

  @dim 64  # Use smaller dimension for faster tests

  describe "random_vector/1" do
    test "generates vector of specified dimension" do
      vec = HRR.random_vector(@dim)
      assert length(vec) == @dim
    end

    test "generates approximately unit length vector" do
      vec = HRR.random_vector(@dim)
      magnitude = vec |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

      assert_in_delta magnitude, 1.0, 0.01
    end

    test "generates different vectors each time" do
      vec1 = HRR.random_vector(@dim)
      vec2 = HRR.random_vector(@dim)

      refute vec1 == vec2
    end
  end

  describe "seeded_vector/2" do
    test "generates consistent vector for same seed" do
      vec1 = HRR.seeded_vector("test_seed", @dim)
      vec2 = HRR.seeded_vector("test_seed", @dim)

      assert vec1 == vec2
    end

    test "generates different vectors for different seeds" do
      vec1 = HRR.seeded_vector("seed_a", @dim)
      vec2 = HRR.seeded_vector("seed_b", @dim)

      refute vec1 == vec2
    end
  end

  describe "normalize/1" do
    test "normalizes to unit length" do
      vec = [3.0, 4.0]  # magnitude = 5
      normalized = HRR.normalize(vec)

      magnitude = normalized |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
      assert_in_delta magnitude, 1.0, 0.0001
    end

    test "handles zero vector" do
      vec = [0.0, 0.0, 0.0]
      normalized = HRR.normalize(vec)

      assert normalized == [0.0, 0.0, 0.0]
    end
  end

  describe "similarity/2" do
    test "identical vectors have similarity 1.0" do
      vec = HRR.random_vector(@dim)
      sim = HRR.similarity(vec, vec)

      assert_in_delta sim, 1.0, 0.01
    end

    test "orthogonal vectors have similarity near 0" do
      # For high-dimensional random vectors, they're approximately orthogonal
      vec1 = HRR.random_vector(256)
      vec2 = HRR.random_vector(256)
      sim = HRR.similarity(vec1, vec2)

      assert abs(sim) < 0.3
    end

    test "negated vector has similarity -1.0" do
      vec = HRR.random_vector(@dim)
      negated = Enum.map(vec, &(-&1))
      sim = HRR.similarity(vec, negated)

      assert_in_delta sim, -1.0, 0.01
    end
  end

  describe "bundle/1" do
    test "bundles multiple vectors into one" do
      vecs = for _ <- 1..5, do: HRR.random_vector(@dim)
      bundled = HRR.bundle(vecs)

      assert length(bundled) == @dim
    end

    test "bundled vector is normalized" do
      vecs = for _ <- 1..5, do: HRR.random_vector(@dim)
      bundled = HRR.bundle(vecs)

      magnitude = bundled |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
      assert_in_delta magnitude, 1.0, 0.01
    end

    test "single vector bundle returns that vector" do
      vec = HRR.random_vector(@dim)
      bundled = HRR.bundle([vec])

      assert bundled == vec
    end

    test "bundled vector is similar to all components" do
      vecs = for _ <- 1..3, do: HRR.random_vector(@dim)
      bundled = HRR.bundle(vecs)

      # Each component should have non-trivial similarity
      for vec <- vecs do
        sim = HRR.similarity(bundled, vec)
        assert sim > 0.2
      end
    end
  end

  describe "bind and unbind" do
    test "bind creates combined representation" do
      role = HRR.random_vector(@dim)
      filler = HRR.random_vector(@dim)

      bound = HRR.bind(role, filler)

      # Bound should be different from both inputs
      refute HRR.similarity(bound, role) > 0.5
      refute HRR.similarity(bound, filler) > 0.5
    end

    test "unbind approximately recovers filler" do
      role = HRR.seeded_vector("role", @dim)
      filler = HRR.seeded_vector("filler", @dim)

      bound = HRR.bind(role, filler)
      recovered = HRR.unbind(bound, role)

      # Recovered should be similar to original filler
      sim = HRR.similarity(recovered, filler)
      assert sim > 0.3
    end
  end

  describe "probe/2" do
    test "probing with cue gives correlation" do
      memory = HRR.random_vector(@dim)
      cue = memory  # Same as memory

      probe_result = HRR.probe(memory, cue)
      assert_in_delta probe_result, 1.0, 0.01
    end
  end

  describe "decode/2" do
    test "decodes closest match from codebook" do
      # Create a codebook
      codebook = %{
        a: HRR.seeded_vector("a", @dim),
        b: HRR.seeded_vector("b", @dim),
        c: HRR.seeded_vector("c", @dim)
      }

      # Query with one of the vectors (slightly noisy)
      query = HRR.seeded_vector("b", @dim)
      |> HRR.add(HRR.scale(HRR.random_vector(@dim), 0.1))
      |> HRR.normalize()

      {match, similarity} = HRR.decode(query, codebook)

      assert match == :b
      assert similarity > 0.8
    end

    test "returns nil for empty codebook" do
      result = HRR.decode(HRR.random_vector(@dim), %{})
      assert result == nil
    end
  end

  describe "scale/2" do
    test "scales vector by scalar" do
      vec = [1.0, 2.0, 3.0]
      scaled = HRR.scale(vec, 2.0)

      assert scaled == [2.0, 4.0, 6.0]
    end
  end

  describe "add/2" do
    test "adds vectors element-wise" do
      a = [1.0, 2.0, 3.0]
      b = [4.0, 5.0, 6.0]
      result = HRR.add(a, b)

      assert result == [5.0, 7.0, 9.0]
    end
  end

  describe "serialization" do
    test "to_binary/1 and from_binary/1 roundtrip" do
      original = HRR.random_vector(@dim)
      binary = HRR.to_binary(original)
      restored = HRR.from_binary(binary)

      assert length(restored) == @dim

      # Check values are close (floating point)
      for {orig, rest} <- Enum.zip(original, restored) do
        assert_in_delta orig, rest, 0.0001
      end
    end
  end
end
