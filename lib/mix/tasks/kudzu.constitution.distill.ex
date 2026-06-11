defmodule Mix.Tasks.Kudzu.Constitution.Distill do
  @shortdoc "Distill the U.S. founding canon into the expertise + rejection silos"

  @moduledoc """
  Drives Flow A of the Constitution distillation sub-project.

  Streams chunks from `Kudzu.Constitution.Corpus`, runs each through
  `Brain.Distiller.extract_chains/1` then `SovereigntyFilter.judge/2`,
  routes results via `DistillationRouter.route/4` to the expertise,
  rejection, or contested silo.

  Cost-capped: `--budget-cap-usd N` aborts when token spend exceeds N.
  Default $150 (per spec — covers the ~$60–120 expected range with
  headroom).

  ## Usage

      mix kudzu.constitution.distill                          # full run
      mix kudzu.constitution.distill --per-source 3           # smoke test
      mix kudzu.constitution.distill --budget-cap-usd 50      # tight cap
      mix kudzu.constitution.distill --force-reingest         # not yet implemented (raises)
      mix kudzu.constitution.distill --skip-tyranny           # skip TyrannyArtifacts import
  """
  use Mix.Task

  alias Kudzu.Brain.Distiller
  alias Kudzu.Constitution.Corpus
  alias Kudzu.Constitution.Filter.DistillationRouter
  alias Kudzu.Constitution.Filter.SovereigntyFilter
  alias Kudzu.Constitution.Tyranny.TyrannyArtifacts
  alias Kudzu.Silo

  @default_budget_usd 150.0
  @default_silos %{
    expertise: "expertise:us_constitution_mesh",
    rejection: "rejection:us_constitution_mesh",
    contested: "contested:us_constitution_mesh"
  }

  @impl Mix.Task
  def run(argv) do
    if "--help" in argv or "-h" in argv do
      # `Mix.raise/1` prints the message and raises Mix.Error — the test
      # catches that exception (see Task 19 adaptation note).
      Mix.raise("usage:\n" <> @moduledoc)
    end

    Mix.Task.run("app.start")

    {opts, _rest} = parse_args(argv)

    ensure_silos!(opts)

    unless opts[:skip_tyranny] do
      IO.puts("Importing tyranny.yaml artifacts...")
      count = TyrannyArtifacts.import_all(rejection_silo: @default_silos.rejection)
      IO.puts("  -> #{count} tyranny artifacts in rejection silo")
    end

    IO.puts("Streaming corpus chunks (budget cap: $#{opts[:budget_cap_usd]})...")

    stream =
      case opts[:per_source] do
        nil -> Corpus.stream_chunks()
        n -> Corpus.stream_chunks(per_source: n)
      end

    distill_loop(stream, opts)
  end

  @doc false
  def parse_args(argv) do
    case OptionParser.parse!(argv,
           strict: [
             budget_cap_usd: :float,
             per_source: :integer,
             force_reingest: :boolean,
             skip_tyranny: :boolean,
             help: :boolean
           ],
           aliases: [h: :help]
         ) do
      {opts, rest} ->
        {Keyword.put_new(opts, :budget_cap_usd, @default_budget_usd), rest}
    end
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp ensure_silos!(opts) do
    Enum.each([:expertise, :rejection, :contested], fn key ->
      silo = @default_silos[key]

      case Silo.find(silo) do
        {:ok, _pid} ->
          if opts[:force_reingest], do: clear_silo(silo)
          :ok

        {:error, :not_found} ->
          {:ok, _pid} = Silo.create(silo, %{})
      end
    end)
  end

  # `Silo.delete_trace/2` is not yet implemented (see Task 19 adaptation
  # note). Raise loudly rather than silently continuing — users passing
  # `--force-reingest` expect a clean slate; continuing would produce
  # duplicate-flavored data.
  defp clear_silo(_silo) do
    Mix.raise(
      "--force-reingest is not yet implemented (Silo.delete_trace/2 missing). " <>
        "Manually clear silos and re-run without the flag."
    )
  end

  defp distill_loop(stream, opts) do
    final =
      Enum.reduce_while(stream, %{spent: 0.0, processed: 0}, fn chunk, acc ->
        if acc.spent > opts[:budget_cap_usd] do
          IO.puts(
            "\n!! Budget cap $#{opts[:budget_cap_usd]} exceeded at " <>
              "$#{Float.round(acc.spent, 2)}."
          )

          next_cap = opts[:budget_cap_usd] + 50

          IO.puts("   Resume with: mix kudzu.constitution.distill --budget-cap-usd #{next_cap}")

          {:halt, acc}
        else
          {_triples_extracted, cost} = process_chunk(chunk)
          new_acc = %{acc | spent: acc.spent + cost, processed: acc.processed + 1}

          if rem(new_acc.processed, 10) == 0 do
            IO.write("\r processed #{new_acc.processed}, spent $#{Float.round(new_acc.spent, 2)}")
          end

          {:cont, new_acc}
        end
      end)

    IO.puts(
      "\nDistillation complete: #{final.processed} chunks, " <>
        "$#{Float.round(final.spent, 2)} spent"
    )
  end

  # `Brain.Distiller.extract_chains/1` returns a plain list of triples
  # (or `[]` on extraction failure) — it is NOT a `{:ok, _} | {:error, _}`
  # tuple. Adapted from the plan accordingly.
  defp process_chunk(chunk) do
    triples = Distiller.extract_chains(chunk.text)
    cost = estimate_cost(chunk.text, triples)
    Enum.each(triples, &route_one(&1, chunk))
    {length(triples), cost}
  end

  defp route_one(triple, chunk) do
    case SovereigntyFilter.judge(triple, chunk.text) do
      {:ok, judgment} ->
        provenance = %{
          source_doc: chunk.source_doc,
          paragraph_offset: chunk.paragraph_offset,
          section_label: chunk.section_label
        }

        DistillationRouter.route(triple, judgment, provenance, @default_silos)

      {:error, _} ->
        :skip
    end
  end

  # Rough estimate: $3 per 1M input tokens for Sonnet 4.6.
  # ~4 chars per token; 3 samples per triple * ~500 tokens each.
  # Calibration happens in Task 21.
  defp estimate_cost(text, triples) do
    input_tokens = byte_size(text) / 4
    sample_tokens = length(triples) * 3 * 500
    (input_tokens + sample_tokens) / 1_000_000 * 3.0
  end
end
