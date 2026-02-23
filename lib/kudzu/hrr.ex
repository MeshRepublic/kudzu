defmodule Kudzu.HRR do
  @moduledoc """
  Holographic Reduced Representations (HRR) for compressed memory.

  Uses FFT-based circular convolution for binding (O(n log n)).

  Reference: Plate, T. A. (2003). Holographic Reduced Representation.
  """

  @type vector :: [float()]
  @type dim :: pos_integer()

  @default_dim 512

  @spec default_dim() :: dim()
  def default_dim, do: @default_dim

  @spec random_vector(dim()) :: vector()
  def random_vector(dim \\ @default_dim) do
    raw = for _ <- 1..dim, do: :rand.normal()
    normalize(raw)
  end

  @spec zero_vector(dim()) :: vector()
  def zero_vector(dim \\ @default_dim) do
    List.duplicate(0.0, dim)
  end

  @spec seeded_vector(binary(), dim()) :: vector()
  def seeded_vector(seed, dim \\ @default_dim) when is_binary(seed) do
    hash = :crypto.hash(:sha256, seed)
    <<seed_int::256>> = hash
    :rand.seed(:exsss, {seed_int, seed_int + 1, seed_int + 2})
    random_vector(dim)
  end

  @doc """
  Bind two vectors using FFT-based circular convolution.
  """
  @spec bind(vector(), vector()) :: vector()
  def bind(a, b) when length(a) == length(b) do
    n = length(a)
    fa = fft(Enum.map(a, &{&1, 0.0}))
    fb = fft(Enum.map(b, &{&1, 0.0}))

    # Element-wise complex multiplication
    fc = complex_multiply(fa, fb)

    # Inverse FFT and take real parts
    result = ifft(fc)
    |> Enum.map(fn {real, _imag} -> real / n end)

    normalize(result)
  end

  @spec unbind(vector(), vector()) :: vector()
  def unbind(bound, role) do
    bind(bound, approximate_inverse(role))
  end

  @spec bundle([vector()]) :: vector()
  def bundle([]), do: raise(ArgumentError, "Cannot bundle empty list")
  def bundle([v]), do: v
  def bundle(vectors) do
    dim = length(hd(vectors))
    summed = Enum.reduce(vectors, zero_vector(dim), fn vec, acc ->
      Enum.zip(vec, acc) |> Enum.map(fn {a, b} -> a + b end)
    end)
    normalize(summed)
  end

  @spec probe(vector(), vector()) :: float()
  def probe(memory, cue) when length(memory) == length(cue) do
    Enum.zip(memory, cue)
    |> Enum.map(fn {a, b} -> a * b end)
    |> Enum.sum()
  end

  @spec decode(vector(), %{any() => vector()}) :: {any(), float()} | nil
  def decode(_query, codebook) when map_size(codebook) == 0, do: nil
  def decode(query, codebook) do
    codebook
    |> Enum.map(fn {key, vec} -> {key, probe(query, vec)} end)
    |> Enum.max_by(fn {_key, sim} -> sim end)
  end

  @spec normalize(vector()) :: vector()
  def normalize(vec) do
    mag_sq = Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end)
    if mag_sq == 0.0 do
      vec
    else
      inv_mag = 1.0 / :math.sqrt(mag_sq)
      Enum.map(vec, fn x -> x * inv_mag end)
    end
  end

  @spec similarity(vector(), vector()) :: float()
  def similarity(a, b) when length(a) == length(b) do
    probe(normalize(a), normalize(b))
  end

  @spec add(vector(), vector()) :: vector()
  def add(a, b) when length(a) == length(b) do
    Enum.zip(a, b) |> Enum.map(fn {x, y} -> x + y end)
  end

  @spec scale(vector(), float()) :: vector()
  def scale(vec, scalar) do
    Enum.map(vec, fn x -> x * scalar end)
  end

  @spec to_binary(vector()) :: binary()
  def to_binary(vec) do
    vec |> Enum.map(fn f -> <<f::float-32>> end) |> IO.iodata_to_binary()
  end

  @spec from_binary(binary()) :: vector()
  def from_binary(bin) when is_binary(bin) do
    do_from_binary(bin, []) |> Enum.reverse()
  end

  defp do_from_binary(<<>>, acc), do: acc
  defp do_from_binary(<<f::float-32, rest::binary>>, acc) do
    do_from_binary(rest, [f | acc])
  end

  defp approximate_inverse([first | rest]), do: [first | Enum.reverse(rest)]

  # --- Radix-2 Cooley-Tukey FFT (recursive, list-based) ---

  defp fft([x]), do: [x]
  defp fft(xs) do
    n = length(xs)
    half = div(n, 2)
    {evens, odds} = split_even_odd(xs)

    fft_even = fft(evens)
    fft_odd = fft(odds)

    # Compute twiddle factors and butterfly
    angle_step = -2.0 * :math.pi() / n
    butterflies(fft_even, fft_odd, half, angle_step, 0, [], [])
  end

  defp butterflies([], [], _half, _step, _k, first_acc, second_acc) do
    Enum.reverse(first_acc) ++ Enum.reverse(second_acc)
  end

  defp butterflies([e | es], [o | os], half, step, k, first_acc, second_acc) do
    angle = step * k
    wr = :math.cos(angle)
    wi = :math.sin(angle)

    {or_val, oi_val} = o
    tr = wr * or_val - wi * oi_val
    ti = wr * oi_val + wi * or_val

    {er, ei} = e
    butterflies(es, os, half, step, k + 1,
      [{er + tr, ei + ti} | first_acc],
      [{er - tr, ei - ti} | second_acc])
  end

  defp ifft(xs) do
    n = length(xs)
    conjugated = Enum.map(xs, fn {r, i} -> {r, -i} end)
    result = fft(conjugated)
    Enum.map(result, fn {r, i} -> {r / n, -i / n} end)
  end

  defp split_even_odd(list) do
    do_split(list, 0, [], [])
  end

  defp do_split([], _idx, evens, odds), do: {Enum.reverse(evens), Enum.reverse(odds)}
  defp do_split([h | t], idx, evens, odds) do
    if rem(idx, 2) == 0 do
      do_split(t, idx + 1, [h | evens], odds)
    else
      do_split(t, idx + 1, evens, [h | odds])
    end
  end

  defp complex_multiply(a, b) do
    Enum.zip(a, b)
    |> Enum.map(fn {{ar, ai}, {br, bi}} ->
      {ar * br - ai * bi, ar * bi + ai * br}
    end)
  end
end
