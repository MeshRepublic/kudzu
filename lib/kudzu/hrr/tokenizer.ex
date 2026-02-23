defmodule Kudzu.HRR.Tokenizer do
  @moduledoc """
  Text tokenization for HRR encoding.

  Extracts text from trace reconstruction hints, tokenizes into
  meaningful terms, filters stopwords, and generates bigrams.
  Includes lightweight suffix stemming so related word forms
  (supervisor/supervision, persist/persistence) share tokens.
  """

  @stopwords MapSet.new(~w(
    the a an is was were are be been being have has had do does did
    will would could should may might can shall of to in for on with
    at by from that this it its and or but not no if then than so
    as into also just about more some any all there here when where
    how what which who whom whose very much many too each every both
    few other another such only own same most already really still
  ))

  @min_token_length 2
  @min_stem_length 4

  # Fields to extract from reconstruction hints, in priority order
  @text_fields [:content, :summary, :key_events, :event, :description]

  # Suffix stripping rules, applied in order (longest first).
  # Two passes are applied so compound suffixes converge.
  @suffix_rules [
    # Long compound suffixes
    {"ization", ""},
    {"isation", ""},
    {"ational", ""},
    {"fulness", ""},
    {"iveness", ""},
    {"lessly", ""},
    # Medium suffixes
    {"ation", ""},
    {"ition", ""},
    {"ement", ""},
    {"iment", ""},
    {"ness", ""},
    {"ment", ""},
    {"ence", ""},
    {"ance", ""},
    {"ible", ""},
    {"able", ""},
    {"ious", ""},
    {"eous", ""},
    {"ting", ""},
    {"sing", ""},
    {"sion", ""},
    {"tion", ""},
    {"ally", ""},
    {"age", ""},
    {"val", "v"},
    # Short suffixes
    {"ful", ""},
    {"ive", ""},
    {"ous", ""},
    {"ism", ""},
    {"ist", ""},
    {"ing", ""},
    {"ion", ""},
    {"ity", ""},
    {"ies", "y"},
    {"ied", "y"},
    {"ier", "y"},
    {"ers", ""},
    {"ors", ""},
    {"ure", ""},
    {"ate", ""},
    {"ize", ""},
    {"ise", ""},
    {"ly", ""},
    {"ed", ""},
    {"er", ""},
    {"or", ""},
    {"es", ""},
    {"al", ""},
    {"en", ""},
    {"ss", "ss"},  # protect double-s
    {"le", "l"},
    {"ce", "c"},
    {"se", "s"},
    {"ve", "v"},
    {"te", "t"},
    {"de", "d"},
    {"ne", "n"},
    {"re", "r"},
    {"s", ""}
  ]

  @doc """
  Extract and tokenize text from a trace's reconstruction hint.

  Returns a list of tokens (unigrams + bigrams).
  Includes both original and stemmed forms.
  """
  @spec tokenize_hint(map()) :: [String.t()]
  def tokenize_hint(hint) when is_map(hint) do
    text = extract_text(hint)
    tokenize(text)
  end

  def tokenize_hint(_), do: []

  @doc """
  Extract and tokenize with field labels preserved.

  Returns a list of {field, [tokens]} tuples for multi-field encoding.
  """
  @spec tokenize_hint_by_field(map()) :: [{atom(), [String.t()]}]
  def tokenize_hint_by_field(hint) when is_map(hint) do
    @text_fields
    |> Enum.map(fn field ->
      text = extract_field(hint, field)
      tokens = if text != "", do: tokenize(text), else: []
      {field, tokens}
    end)
    |> Enum.reject(fn {_field, tokens} -> tokens == [] end)
  end

  def tokenize_hint_by_field(_), do: []

  @doc """
  Tokenize a string into unigrams and bigrams.
  Includes stemmed forms alongside originals.
  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    raw_unigrams = extract_raw_unigrams(text)
    stemmed = Enum.map(raw_unigrams, &stem/1)

    # Keep both original and stemmed, deduplicated
    unigrams = (raw_unigrams ++ stemmed) |> Enum.uniq()

    # Bigrams use stemmed forms for better matching
    bigrams = extract_bigrams(stemmed)

    (unigrams ++ bigrams) |> Enum.uniq()
  end

  def tokenize(_), do: []

  @doc """
  Extract only unigrams (no bigrams). Useful for co-occurrence tracking.
  Returns stemmed forms.
  """
  @spec unigrams(String.t()) :: [String.t()]
  def unigrams(text) when is_binary(text) do
    text |> extract_raw_unigrams() |> Enum.map(&stem/1) |> Enum.uniq()
  end

  def unigrams(_), do: []

  @doc """
  Stem a single token using lightweight suffix stripping.
  Applies up to 2 passes to converge related forms.
  """
  @spec stem(String.t()) :: String.t()
  def stem(word) when is_binary(word) do
    pass1 = do_stem(word, @suffix_rules)
    pass2 = do_stem(pass1, @suffix_rules)
    pass2
  end

  # --- Stemming ---

  defp do_stem(word, []) when byte_size(word) >= @min_stem_length, do: word
  defp do_stem(word, []), do: word

  defp do_stem(word, [{suffix, replacement} | rest]) do
    suffix_len = byte_size(suffix)
    word_len = byte_size(word)

    if word_len > suffix_len and String.ends_with?(word, suffix) do
      stem_candidate = String.slice(word, 0, word_len - suffix_len) <> replacement
      if byte_size(stem_candidate) >= @min_stem_length do
        stem_candidate
      else
        do_stem(word, rest)
      end
    else
      do_stem(word, rest)
    end
  end

  # --- Text extraction ---

  defp extract_text(hint) when is_map(hint) do
    field_text =
      @text_fields
      |> Enum.map(&extract_field(hint, &1))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    system_fields = MapSet.new([:timestamp, :type, :machine, :constitution,
                                :from, :to, :associations, :recall_history,
                                :context, :raw])

    extra_text =
      hint
      |> Enum.reject(fn {k, _v} ->
        key = if is_atom(k), do: k, else: String.to_atom("#{k}")
        MapSet.member?(system_fields, key) or Enum.member?(@text_fields, key)
      end)
      |> Enum.map(fn {_k, v} -> to_text(v) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    String.trim("#{field_text} #{extra_text}")
  end

  defp extract_field(hint, field) do
    val = Map.get(hint, field) || Map.get(hint, Atom.to_string(field))
    to_text(val)
  end

  defp to_text(val) when is_binary(val), do: val
  defp to_text(val) when is_atom(val) and not is_nil(val), do: Atom.to_string(val)
  defp to_text(val) when is_number(val), do: ""
  defp to_text(val) when is_list(val) do
    val |> Enum.map(&to_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
  end
  defp to_text(_), do: ""

  # --- Tokenization ---

  defp extract_raw_unigrams(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s\-]/, " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.replace("_", " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&stopword?/1)
    |> Enum.reject(&(String.length(&1) < @min_token_length))
    |> Enum.uniq()
  end

  defp extract_bigrams([]), do: []
  defp extract_bigrams([_]), do: []
  defp extract_bigrams(unigrams) do
    unigrams
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> "#{a}_#{b}" end)
    |> Enum.uniq()
  end

  defp stopword?(word), do: MapSet.member?(@stopwords, word)
end
