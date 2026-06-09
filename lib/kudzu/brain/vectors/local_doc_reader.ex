defmodule Kudzu.Brain.Vectors.LocalDocReader do
  @moduledoc """
  Reads local documentation, READMEs, and source files to learn about topics.

  Searches known documentation paths for files matching the topic,
  then reads and returns their contents.
  """

  @behaviour Kudzu.Brain.Vectors.Behaviour

  require Logger

  @search_paths [
    "/home/eel/kudzu_src",
    "/home/eel/claude",
    "/usr/share/doc"
  ]

  @doc_patterns [
    "README*",
    "CHANGELOG*",
    "docs/**/*.md",
    "doc/**/*.md",
    "*.md"
  ]

  @max_file_bytes 8_192
  @max_total_bytes 20_000

  @doc_keywords ~w(readme config documentation docs guide tutorial
    changelog license contributing setup install)
  @project_keywords ~w(kudzu hologram brain silo beamlet constitution
    mesh vector trace consolidation)

  @impl true
  def name, do: :local_doc_reader

  @impl true
  def relevance(topic) do
    t = String.downcase(topic)
    score = 0.2

    doc_boost = Enum.count(@doc_keywords, &String.contains?(t, &1)) * 0.1
    project_boost = Enum.count(@project_keywords, &String.contains?(t, &1)) * 0.12

    # File paths are great for this vector
    path_boost = if Regex.match?(~r/[\/\\]|\.ex|\.md|\.txt/, t), do: 0.3, else: 0.0

    min(score + doc_boost + project_boost + path_boost, 1.0)
  end

  @impl true
  def available?, do: true

  @impl true
  def learn(topic, _opts \\ []) do
    files = find_relevant_files(topic)

    if files == [] do
      {:error, :no_matching_files}
    else
      {content, files_read} = read_files(files)

      {:ok,
       %{
         content: content,
         source: "local_docs",
         confidence: 0.65,
         metadata: %{files_read: files_read, files_found: length(files)}
       }}
    end
  end

  # ── File Discovery ──────────────────────────────────────────────

  defp find_relevant_files(topic) do
    t = String.downcase(topic)
    keywords = extract_keywords(t)

    @search_paths
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn base_path ->
      find_in_path(base_path, keywords, t)
    end)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp find_in_path(base_path, keywords, topic) do
    # First try doc patterns
    doc_files =
      @doc_patterns
      |> Enum.flat_map(fn pattern ->
        Path.wildcard(Path.join(base_path, pattern))
      end)
      |> Enum.filter(&File.regular?/1)

    # Filter by keyword relevance
    relevant_docs =
      Enum.filter(doc_files, fn path ->
        name = path |> Path.basename() |> String.downcase()
        dir = path |> Path.dirname() |> String.downcase()

        Enum.any?(keywords, fn kw ->
          String.contains?(name, kw) or String.contains?(dir, kw)
        end)
      end)

    # If topic mentions specific source files, search .ex files
    source_files =
      if Regex.match?(~r/\b(module|function|code|source|impl)\b/, topic) do
        find_source_files(base_path, keywords)
      else
        []
      end

    # If no keyword matches, return general READMEs
    if relevant_docs == [] and source_files == [] do
      Enum.filter(doc_files, fn path ->
        name = Path.basename(path) |> String.downcase()
        String.starts_with?(name, "readme")
      end)
      |> Enum.take(3)
    else
      relevant_docs ++ source_files
    end
  end

  defp find_source_files(base_path, keywords) do
    lib_path = Path.join(base_path, "lib")

    if File.dir?(lib_path) do
      Path.wildcard(Path.join(lib_path, "**/*.ex"))
      |> Enum.filter(fn path ->
        name = path |> Path.basename(".ex") |> String.downcase()
        Enum.any?(keywords, &String.contains?(name, &1))
      end)
      |> Enum.take(5)
    else
      []
    end
  end

  defp extract_keywords(topic) do
    topic
    |> String.split(~r/[\s,;:]+/, trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(fn w -> byte_size(w) < 3 end)
    |> Enum.reject(fn w -> w in ~w(the and for how what why about learn explain) end)
  end

  # ── File Reading ────────────────────────────────────────────────

  defp read_files(files) do
    {contents, _total_bytes, count} =
      Enum.reduce_while(files, {[], 0, 0}, fn path, {acc, bytes, n} ->
        if bytes >= @max_total_bytes do
          {:halt, {acc, bytes, n}}
        else
          case File.read(path) do
            {:ok, content} ->
              truncated = String.slice(content, 0, @max_file_bytes)
              relative = make_relative(path)
              entry = "## #{relative}\n\n```\n#{truncated}\n```"
              {:cont, {[entry | acc], bytes + byte_size(truncated), n + 1}}

            {:error, _} ->
              {:cont, {acc, bytes, n}}
          end
        end
      end)

    combined = contents |> Enum.reverse() |> Enum.join("\n\n---\n\n")
    {combined, count}
  end

  defp make_relative(path) do
    cond do
      String.starts_with?(path, "/home/eel/kudzu_src/") ->
        String.replace_prefix(path, "/home/eel/kudzu_src/", "kudzu_src/")

      String.starts_with?(path, "/home/eel/claude/") ->
        String.replace_prefix(path, "/home/eel/claude/", "claude/")

      true ->
        path
    end
  end
end
