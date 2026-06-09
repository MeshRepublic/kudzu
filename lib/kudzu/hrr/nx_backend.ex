defmodule Kudzu.HRR.NxBackend do
  @moduledoc """
  Nx tensor-based HRR (Holographic Reduced Representations) backend.

  Replaces the pure-Elixir list-based implementation with Nx tensor
  operations for significant performance gains. Uses EXLA for XLA/GPU
  acceleration when available (RTX 4090 via CUDA).

  Hot-path algebraic functions use Nx.Defn (`defn`) which compiles to
  XLA and runs on GPU automatically. FFT-based operations use regular
  Nx calls (FFT length must be a compile-time value, incompatible with defn).

  All public functions accept and return plain Elixir lists to maintain
  API compatibility with the legacy backend.
  """

  import Nx.Defn

  @type vector :: [float()]
  @type dim :: pos_integer()

  @default_dim 512

  # --- Compiled (defn) tensor operations ---
  # These compile to XLA and run on GPU when EXLA backend is configured.

  @doc false
  defn normalize_tensor(tensor) do
    norm = Nx.LinAlg.norm(tensor)
    # Use Nx.select instead of if/else — defn-compatible
    safe_norm = Nx.select(norm == 0.0, 1.0, norm)
    Nx.divide(tensor, safe_norm)
  end

  @doc false
  defn similarity_tensors(ta, tb) do
    na = normalize_tensor(ta)
    nb = normalize_tensor(tb)
    Nx.dot(na, nb)
  end

  @doc false
  defn batch_similarity_tensors(tq, matrix) do
    nq = normalize_tensor(tq)
    Nx.dot(matrix, nq)
  end

  # Complex element-wise multiplication of two complex tensors.
  # Used inside bind/2 — not defn because FFT requires compile-time length.
  defp complex_multiply(a, b) do
    ar = Nx.real(a)
    ai = Nx.imag(a)
    br = Nx.real(b)
    bi = Nx.imag(b)

    real = Nx.subtract(Nx.multiply(ar, br), Nx.multiply(ai, bi))
    imag = Nx.add(Nx.multiply(ar, bi), Nx.multiply(ai, br))

    Nx.complex(real, imag)
  end

  # --- Public API ---

  @doc """
  Bind two vectors using FFT-based circular convolution.

  Converts to Nx tensors, applies FFT, element-wise complex multiply
  in frequency domain, then IFFT back. Returns a normalized list.
  Runs on GPU via EXLA backend (Nx.fft requires compile-time length,
  so this uses regular Nx calls rather than defn).
  """
  @spec bind(vector(), vector()) :: vector()
  def bind(a, b) when is_list(a) and is_list(b) do
    n = length(a)
    ta = Nx.tensor(a, type: :f64)
    tb = Nx.tensor(b, type: :f64)

    fa = Nx.fft(ta, length: n)
    fb = Nx.fft(tb, length: n)

    fc = complex_multiply(fa, fb)

    result = Nx.ifft(fc, length: n)
    real_part = Nx.real(result)

    real_part
    |> normalize_tensor()
    |> Nx.to_flat_list()
  end

  @doc """
  Bundle multiple vectors by element-wise addition, then normalize.
  """
  @spec bundle([vector()]) :: vector()
  def bundle([]), do: raise(ArgumentError, "Cannot bundle empty list")
  def bundle([v]) when is_list(v), do: v

  def bundle(vectors) when is_list(vectors) do
    tensors = Enum.map(vectors, &Nx.tensor(&1, type: :f64))

    # Stack into a matrix and sum along axis 0
    stacked = Nx.stack(tensors)
    summed = Nx.sum(stacked, axes: [0])

    summed
    |> normalize_tensor()
    |> Nx.to_flat_list()
  end

  @doc """
  Cosine similarity between two vectors.

  Returns dot(normalize(a), normalize(b)).
  Compiled to XLA via defn for GPU acceleration.
  """
  @spec similarity(vector(), vector()) :: float()
  def similarity(a, b) when is_list(a) and is_list(b) do
    ta = Nx.tensor(a, type: :f64)
    tb = Nx.tensor(b, type: :f64)

    similarity_tensors(ta, tb)
    |> Nx.to_number()
  end

  @doc """
  Generate a deterministic random vector from a seed string.

  Uses :rand.seed/2 with a hash of the seed to produce reproducible
  random values, then converts to a normalized Nx tensor.
  """
  @spec seeded_vector(binary(), dim()) :: vector()
  def seeded_vector(seed, dim \\ @default_dim) when is_binary(seed) do
    hash = :crypto.hash(:sha256, seed)
    <<seed_int::256>> = hash
    :rand.seed(:exsss, {seed_int, seed_int + 1, seed_int + 2})

    raw = for _ <- 1..dim, do: :rand.normal()

    Nx.tensor(raw, type: :f64)
    |> normalize_tensor()
    |> Nx.to_flat_list()
  end

  @doc """
  Normalize a vector to unit length (L2 norm).
  """
  @spec normalize(vector()) :: vector()
  def normalize(vec) when is_list(vec) do
    Nx.tensor(vec, type: :f64)
    |> normalize_tensor()
    |> Nx.to_flat_list()
  end

  @doc """
  Batch similarity: compare one query vector against N candidate vectors.

  Returns a list of similarity scores. Much faster than N individual
  similarity calls because it uses a single batched matrix-vector dot product.
  Candidates are pre-normalized and the matrix multiply runs on GPU via defn.
  """
  @spec batch_similarity(vector(), [vector()]) :: [float()]
  def batch_similarity(_query, []), do: []

  def batch_similarity(query, candidates) when is_list(query) and is_list(candidates) do
    tq = Nx.tensor(query, type: :f64)

    # Build matrix of normalized candidates: each row is a candidate vector
    candidate_tensors =
      Enum.map(candidates, fn c ->
        Nx.tensor(c, type: :f64) |> normalize_tensor()
      end)

    matrix = Nx.stack(candidate_tensors)

    # Batched dot product via defn — runs on GPU
    batch_similarity_tensors(tq, matrix)
    |> Nx.to_flat_list()
  end
end
