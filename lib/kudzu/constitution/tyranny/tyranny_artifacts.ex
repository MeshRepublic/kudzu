defmodule Kudzu.Constitution.Tyranny.TyrannyArtifacts do
  @moduledoc """
  Importer for the tyranny artifact manifest at
  `priv/constitution/tyranny.yaml`.

  Each entry in the manifest describes a historical anti-sovereignty
  artifact (statute, ruling, executive action) whose *principle* is
  what the rejection silo must learn to recognize. The importer:

    1. Loads the YAML manifest.
    2. Validates required fields per entry.
    3. For every entry not already present (by citation), writes a
       triple `{"historical_act", "retards", description}` to the
       rejection silo via `Kudzu.Silo.store_relationship/3`, attaching
       provenance (`:origin_type => :tyranny_artifact`, citation, year,
       principle, source URL, rejection reason).

  The HRR vector bound by `store_relationship/3` is what generalizes —
  the principle-general description vectorizes to a region of HRR
  space that future text whose vector lies nearby will register as
  related, even when the statute name has changed.

  ## Idempotency

  Citations are read from the silo on every call; entries whose
  citation is already represented in the silo are skipped. Running
  `import_all/1` repeatedly converges to a stable trace count.
  """

  require Logger

  alias Kudzu.Silo

  @required_keys ~w(name year citation description principle_violated)

  @default_manifest_subpath "constitution/tyranny.yaml"

  @doc """
  Import every entry from the manifest into the rejection silo.

  Options:

    * `:rejection_silo` — silo domain to write into. Required.
    * `:manifest_path` — absolute path to the YAML manifest. Defaults to
      `priv/constitution/tyranny.yaml` resolved from the `:kudzu`
      priv dir (with a project-root fallback when priv is not yet
      packaged).

  Returns the total number of traces in the silo after the import
  (i.e. previously-present + newly-added). This makes the function
  cheap to call repeatedly: subsequent calls just observe the stable
  count.
  """
  @spec import_all(keyword()) :: non_neg_integer()
  def import_all(opts) when is_list(opts) do
    silo = Keyword.fetch!(opts, :rejection_silo)
    path = Keyword.get(opts, :manifest_path, default_manifest_path())

    entries = load_manifest!(path)

    {:ok, validated} = validate_manifest(entries)

    existing_citations = existing_citations(silo)

    Enum.each(validated, fn entry ->
      citation = Map.fetch!(entry, "citation")

      if MapSet.member?(existing_citations, citation) do
        Logger.debug("[TyrannyArtifacts] skipping duplicate citation: #{citation}")
      else
        write_entry(silo, entry)
      end
    end)

    length(Silo.list_traces(silo))
  end

  @doc """
  Validate every entry in a parsed manifest.

  Returns `{:ok, entries}` if every entry has all required keys, or
  `{:error, [reason, ...]}` listing every problem found (one reason
  per offending entry).
  """
  @spec validate_manifest([map()]) :: {:ok, [map()]} | {:error, [String.t()]}
  def validate_manifest(entries) when is_list(entries) do
    errors =
      entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, idx} -> validate_entry(entry, idx) end)

    case errors do
      [] -> {:ok, entries}
      _ -> {:error, errors}
    end
  end

  # --- private ---------------------------------------------------------

  defp validate_entry(entry, idx) when is_map(entry) do
    missing = Enum.reject(@required_keys, &Map.has_key?(entry, &1))

    case missing do
      [] ->
        []

      _ ->
        name = Map.get(entry, "name", "<unnamed>")

        [
          "entry #{idx} (#{name}) is missing required field(s): #{Enum.join(missing, ", ")}"
        ]
    end
  end

  defp validate_entry(_other, idx) do
    ["entry #{idx} is missing required field(s): not a map"]
  end

  defp load_manifest!(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, entries} when is_list(entries) ->
        entries

      {:ok, other} ->
        raise "tyranny manifest at #{path} must be a YAML list, got: #{inspect(other)}"

      {:error, reason} ->
        raise "failed to read tyranny manifest at #{path}: #{inspect(reason)}"
    end
  end

  defp default_manifest_path do
    case :code.priv_dir(:kudzu) do
      {:error, :bad_name} ->
        Path.expand("priv/" <> @default_manifest_subpath)

      priv when is_list(priv) ->
        Path.join(List.to_string(priv), @default_manifest_subpath)
    end
  end

  defp existing_citations(silo) do
    silo
    |> Silo.list_traces()
    |> Enum.reduce(MapSet.new(), fn trace, acc ->
      case Map.get(trace.reconstruction_hint || %{}, :citation) do
        nil -> acc
        citation -> MapSet.put(acc, citation)
      end
    end)
  end

  defp write_entry(silo, entry) do
    description = Map.fetch!(entry, "description")
    name = Map.fetch!(entry, "name")
    citation = Map.fetch!(entry, "citation")
    year = Map.fetch!(entry, "year")
    principle = Map.fetch!(entry, "principle_violated")
    source_url = Map.get(entry, "source_url")

    provenance = %{
      origin_type: :tyranny_artifact,
      source_doc: name,
      citation: citation,
      year: year,
      principle: principle,
      rejection_reason: description,
      source_url: source_url
    }

    case Silo.store_relationship(silo, {"historical_act", "retards", description}, provenance) do
      {:ok, _trace} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[TyrannyArtifacts] failed to write #{name} (#{citation}): #{inspect(reason)}"
        )

        :error
    end
  end
end
