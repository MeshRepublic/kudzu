defmodule Kudzu.HRR do
  @moduledoc """
  Holographic Reduced Representations (HRR) for compressed memory.

  HRR is a mathematical framework for encoding structured information
  into high-dimensional vectors that can be combined using circular
  convolution while preserving the ability to retrieve individual components.

  ## Key Operations

  - **Encoding**: Convert traces to high-dimensional vectors
  - **Binding**: Combine role-filler pairs (circular convolution)
  - **Bundling**: Superimpose multiple vectors (addition + normalization)
  - **Probing**: Retrieve information using correlation

  ## Why HRR for Agent Memory?

  1. **Compression**: Thousands of traces → single fixed-size vector
  2. **Associative**: Similar memories activate together
  3. **Composable**: Combine memories without losing structure
  4. **Noise-tolerant**: Partial matches work (graceful degradation)

  ## Mathematical Foundation

  Based on circular convolution in the frequency domain:
  - Binding: a ⊛ b = IFFT(FFT(a) ⊙ FFT(b))
  - Unbinding: a ⊛⁻¹ b = a ⊛ b' where b' is approximate inverse

  Reference: Plate, T. A. (2003). Holographic Reduced Representation:
  Distributed Representation for Cognitive Structures.
  """

  @type vector :: [float()]
  @type dim :: pos_integer()

  # Default dimension for HRR vectors
  # Higher = more capacity but more compute
  @default_dim 512

  @doc """
  Get the default vector dimension.
  """
  @spec default_dim() :: dim()
  def default_dim, do: @default_dim

  @doc """
  Generate a random unit vector (role/filler vector).
  """
  @spec random_vector(dim()) :: vector()
  def random_vector(dim \\ @default_dim) do
    # Generate random values and normalize to unit length
    raw = for _ <- 1..dim, do: :rand.normal()
    normalize(raw)
  end

  @doc """
  Generate a zero vector.
  """
  @spec zero_vector(dim()) :: vector()
  def zero_vector(dim \\ @default_dim) do
    List.duplicate(0.0, dim)
  end

  @doc """
  Generate a vector from a seed (deterministic).
  Same seed always produces same vector.
  """
  @spec seeded_vector(binary(), dim()) :: vector()
  def seeded_vector(seed, dim \\ @default_dim) when is_binary(seed) do
    # Use seed to initialize deterministic random state
    hash = :crypto.hash(:sha256, seed)
    <<seed_int::256>> = hash

    # Use the hash to seed random number generation
    :rand.seed(:exsss, {seed_int, seed_int + 1, seed_int + 2})

    random_vector(dim)
  end

  @doc """
  Bind two vectors using circular convolution.
  This creates a combined representation that can be unbound later.

  bind(role, filler) -> bound
  unbind(bound, role) ≈ filler
  """
  @spec bind(vector(), vector()) :: vector()
  def bind(a, b) when length(a) == length(b) do
    # Circular convolution (direct computation)
    # For HRR dimensions (512), this is fast enough
    # For larger vectors, would use FFT-based approach
    n = length(a)
    a_arr = :array.from_list(a)
    b_arr = :array.from_list(b)

    result = for i <- 0..(n-1) do
      sum = Enum.reduce(0..(n-1), 0.0, fn j, acc ->
        # Circular convolution: c[i] = sum_j a[j] * b[(i-j) mod n]
        idx = rem(i - j + n, n)
        acc + :array.get(j, a_arr) * :array.get(idx, b_arr)
      end)
      sum
    end

    normalize(result)
  end

  @doc """
  Unbind (approximate inverse of bind).
  If c = bind(a, b), then unbind(c, a) ≈ b

  Uses the approximate inverse: inv(v) = v rotated by 1 position
  """
  @spec unbind(vector(), vector()) :: vector()
  def unbind(bound, role) do
    # Approximate inverse is the vector with elements in reverse order
    # (except first element stays in place)
    inv_role = approximate_inverse(role)
    bind(bound, inv_role)
  end

  @doc """
  Bundle (superimpose) multiple vectors.
  The result contains information from all input vectors.
  """
  @spec bundle([vector()]) :: vector()
  def bundle([]), do: raise(ArgumentError, "Cannot bundle empty list")
  def bundle([v]), do: v
  def bundle(vectors) do
    # Element-wise addition and normalize
    dim = length(hd(vectors))

    summed = Enum.reduce(vectors, zero_vector(dim), fn vec, acc ->
      Enum.zip(vec, acc)
      |> Enum.map(fn {a, b} -> a + b end)
    end)

    normalize(summed)
  end

  @doc """
  Probe a memory vector with a cue.
  Returns similarity (correlation) between result and target.
  """
  @spec probe(vector(), vector()) :: float()
  def probe(memory, cue) when length(memory) == length(cue) do
    # Dot product (cosine similarity for unit vectors)
    Enum.zip(memory, cue)
    |> Enum.map(fn {a, b} -> a * b end)
    |> Enum.sum()
  end

  @doc """
  Find the most similar vector from a codebook.
  Returns {best_match_key, similarity_score}.
  """
  @spec decode(vector(), %{any() => vector()}) :: {any(), float()} | nil
  def decode(_query, codebook) when map_size(codebook) == 0, do: nil
  def decode(query, codebook) do
    codebook
    |> Enum.map(fn {key, vec} -> {key, probe(query, vec)} end)
    |> Enum.max_by(fn {_key, sim} -> sim end)
  end

  @doc """
  Normalize a vector to unit length.
  """
  @spec normalize(vector()) :: vector()
  def normalize(vec) do
    magnitude = vec
    |> Enum.map(fn x -> x * x end)
    |> Enum.sum()
    |> :math.sqrt()

    if magnitude == 0 do
      vec
    else
      Enum.map(vec, fn x -> x / magnitude end)
    end
  end

  @doc """
  Calculate cosine similarity between two vectors.
  """
  @spec similarity(vector(), vector()) :: float()
  def similarity(a, b) when length(a) == length(b) do
    # For normalized vectors, this equals the dot product
    probe(normalize(a), normalize(b))
  end

  @doc """
  Add two vectors element-wise (without normalization).
  """
  @spec add(vector(), vector()) :: vector()
  def add(a, b) when length(a) == length(b) do
    Enum.zip(a, b)
    |> Enum.map(fn {x, y} -> x + y end)
  end

  @doc """
  Scale a vector by a scalar.
  """
  @spec scale(vector(), float()) :: vector()
  def scale(vec, scalar) do
    Enum.map(vec, fn x -> x * scalar end)
  end

  @doc """
  Serialize a vector to binary for compact storage.
  """
  @spec to_binary(vector()) :: binary()
  def to_binary(vec) do
    vec
    |> Enum.map(fn f -> <<f::float-32>> end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Deserialize a vector from binary.
  """
  @spec from_binary(binary()) :: vector()
  def from_binary(bin) when is_binary(bin) do
    do_from_binary(bin, [])
    |> Enum.reverse()
  end

  defp do_from_binary(<<>>, acc), do: acc
  defp do_from_binary(<<f::float-32, rest::binary>>, acc) do
    do_from_binary(rest, [f | acc])
  end

  # Approximate inverse for unbinding
  # The inverse of a vector v is approximately v with elements reversed
  # (except first element stays in place)
  defp approximate_inverse([first | rest]) do
    [first | Enum.reverse(rest)]
  end
end
