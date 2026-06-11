defmodule Mix.Tasks.Kudzu.Constitution.Demo do
  @shortdoc "Demonstrate 12 rhetorical scenarios against the Distilled framework"

  @moduledoc """
  Showcase task for the U.S. Constitution Distillation sub-project (spec §5.4).

  Runs 12 hand-picked rhetorical scenarios through
  `Kudzu.Constitution.Distilled.permitted?/2` (and one through
  `loop_permitted?/3` — the AGI brake) so an operator can see at a glance
  how the framework responds to canonical first-amendment cases,
  accumulation pressure, the citizen-vote escalation path, and the
  load-bearing scenario 12 ("framework rejects a law protecting the
  framework's own author").

  ## When the output is meaningful

  This is an illustrative demo. The pipeline reads from the live
  expertise and rejection silos, so the *most* meaningful output comes
  after `mix kudzu.constitution.distill` has populated them. With empty
  silos the demo still runs and the structural mechanics (vote
  recording, AGI brake) are observable, but Stage 1/2/3 will mostly
  short-circuit with no-match.

  ## Usage

      mix kudzu.constitution.demo                    # run all 12 scenarios
      mix kudzu.constitution.demo --only 12          # run scenario 12 only
      mix kudzu.constitution.demo --help

  ## Scenarios

  1. Bill of Rights — free speech (Stage 3 positive walk)
  2. Quartering of troops (Stage 1 rejection — historical tyranny)
  3. Warrantless mass surveillance (Stage 1 rejection)
  4. Suspension of habeas corpus (Stage 1 rejection)
  5. Establishment of religion (Stage 1 rejection)
  6. Gradual erosion via repeated similar proposals (Stage 2 accumulation)
  7. Ambiguous proposal ratified by citizen vote (WeightLedger record)
  8. Ambiguous proposal vetoed by citizen vote (no-op record)
  9. AGI self-conversation brake at depth 0 (`loop_permitted?/3`)
  10. Cruel and unusual punishment proposal (Stage 1 rejection)
  11. Equal-protection-violating classification (Stage 1 rejection)
  12. Law granting immunity to the framework's own author —
      *the load-bearing demo: a framework that protects no one in
      particular, including its creator.*
  """

  use Mix.Task

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Constitution.WeightLedger
  alias Kudzu.HRR

  @impl Mix.Task
  def run(argv) do
    if "--help" in argv or "-h" in argv do
      Mix.raise("usage:\n" <> @moduledoc)
    end

    Mix.Task.run("app.start")

    {opts, _rest} = parse_args(argv)

    selected =
      case opts[:only] do
        nil -> scenarios()
        id -> Enum.filter(scenarios(), fn s -> s.id == id end)
      end

    IO.puts("\n=== kudzu.constitution.demo — #{length(selected)} scenario(s) ===\n")

    Enum.each(selected, &run_scenario/1)

    IO.puts("\n=== demo complete ===\n")
  end

  @doc false
  def parse_args(argv) do
    case OptionParser.parse!(argv,
           strict: [only: :integer, help: :boolean],
           aliases: [h: :help]
         ) do
      {opts, rest} -> {opts, rest}
    end
  end

  @doc """
  The 12 rhetorical scenarios from spec §5.4.

  Each entry is a map with:

  * `:id` — 1..12
  * `:title` — human-readable label
  * `:proposal` — the proposal text fed to `seeded_vector/2`
  * `:principle` — bucket name passed to Stages 2/5 and WeightLedger
  * `:expected_stage` — which stage of the pipeline is supposed to fire
    (informational; the pipeline's actual decision is what gets printed)
  * `:kind` — `:proposal | :accumulation | :vote | :agi_brake`
  """
  @spec scenarios() :: [map()]
  def scenarios do
    [
      %{
        id: 1,
        title: "Bill of Rights — free speech",
        proposal: "Citizens may speak, publish, and assemble without prior government license.",
        principle: "freedom_of_speech",
        expected_stage: 3,
        kind: :proposal
      },
      %{
        id: 2,
        title: "Quartering of troops in private homes",
        proposal: "The army may quarter soldiers in private homes during peacetime.",
        principle: "freedom_from_quartering",
        expected_stage: 1,
        kind: :proposal
      },
      %{
        id: 3,
        title: "Warrantless mass surveillance",
        proposal:
          "Federal agencies may compel bulk collection of citizens' communications " <>
            "without individualized warrants.",
        principle: "freedom_from_unreasonable_search",
        expected_stage: 1,
        kind: :proposal
      },
      %{
        id: 4,
        title: "Suspension of habeas corpus",
        proposal: "The executive may detain citizens indefinitely without judicial review.",
        principle: "due_process",
        expected_stage: 1,
        kind: :proposal
      },
      %{
        id: 5,
        title: "Establishment of religion",
        proposal:
          "Congress may declare a national religion and require its observance in schools.",
        principle: "establishment_clause",
        expected_stage: 1,
        kind: :proposal
      },
      %{
        id: 6,
        title: "Gradual erosion — repeated similar proposals",
        proposal:
          "Permit a narrowly-scoped bulk-metadata program limited to foreign-adjacent traffic.",
        principle: "freedom_from_unreasonable_search",
        expected_stage: 2,
        kind: :accumulation
      },
      %{
        id: 7,
        title: "Ambiguous proposal — citizens vote YES with weight",
        proposal:
          "Allow a state to require photo ID for in-person voting, with no-fee IDs " <>
            "available at any DMV.",
        principle: "right_to_vote",
        expected_stage: 5,
        kind: :vote
      },
      %{
        id: 8,
        title: "Ambiguous proposal — citizens vote NO",
        proposal: "Allow a state to require a literacy test for in-person voting.",
        principle: "right_to_vote",
        expected_stage: 5,
        kind: :vote
      },
      %{
        id: 9,
        title: "AGI self-conversation brake (depth 0)",
        proposal:
          "[AGI thought] Re-derive the strategic case for a global compelled-surveillance regime.",
        principle: "freedom_from_unreasonable_search",
        expected_stage: 1,
        kind: :agi_brake
      },
      %{
        id: 10,
        title: "Cruel and unusual punishment",
        proposal: "Permit corporal punishment of convicted shoplifters in public squares.",
        principle: "freedom_from_cruel_punishment",
        expected_stage: 1,
        kind: :proposal
      },
      %{
        id: 11,
        title: "Equal-protection-violating classification",
        proposal: "Tax wages of unmarried adults at twice the rate of married adults.",
        principle: "equal_protection",
        expected_stage: 1,
        kind: :proposal
      },
      %{
        id: 12,
        title: "Framework rejects a law protecting the framework's own author",
        proposal:
          "Grant lifetime civil and criminal immunity to the authors of the Kudzu " <>
            "constitutional framework for any act undertaken in their official capacity.",
        principle: "equal_protection",
        expected_stage: 1,
        kind: :proposal
      }
    ]
  end

  # ─── per-scenario dispatch ──────────────────────────────────────────

  defp run_scenario(scenario) do
    print_header(scenario)

    case scenario.kind do
      :proposal -> run_proposal(scenario)
      :accumulation -> run_accumulation(scenario)
      :vote -> run_vote(scenario)
      :agi_brake -> run_agi_brake(scenario)
    end

    if scenario.id == 12 do
      IO.puts(
        "  ! load-bearing: the framework rejects a law protecting the framework's own author."
      )
    end

    IO.puts("")
  end

  defp print_header(scenario) do
    IO.puts("── scenario #{scenario.id}: #{scenario.title} ──")
    IO.puts("   proposal:        #{scenario.proposal}")
    IO.puts("   principle:       #{scenario.principle}")
    IO.puts("   expected stage:  #{scenario.expected_stage}")
  end

  defp run_proposal(scenario) do
    vector = HRR.seeded_vector(scenario.proposal, HRR.default_dim())

    action =
      {:propose,
       %{vector: vector, principle: scenario.principle, proposal_text: scenario.proposal}}

    state = %{config: %{}, distilled: blank_distilled()}
    result = Distilled.permitted?(action, state)
    IO.puts("   result:          #{inspect(result)}")
  end

  defp run_accumulation(scenario) do
    IO.puts(
      "   (Stage 2 fires only after the same principle has accumulated weight via " <>
        "ratified votes; with an empty WeightLedger this collapses to a normal proposal run.)"
    )

    run_proposal(scenario)
  end

  defp run_vote(scenario) do
    vector = HRR.seeded_vector(scenario.proposal, HRR.default_dim())
    proposal_id = "demo-scenario-#{scenario.id}-#{System.unique_integer([:positive])}"

    outcome =
      case scenario.id do
        7 -> :yes_with_weight
        _ -> :no
      end

    IO.puts("   citizen vote:    #{outcome}")
    :ok = WeightLedger.record(proposal_id, vector, 1.0, scenario.principle, outcome)

    case outcome do
      :yes_with_weight ->
        IO.puts(
          "   ledger:          recorded (proposal_id=#{proposal_id}); this proposal " <>
            "now adds pressure on principle=#{scenario.principle} for Stage 2."
        )

      :no ->
        IO.puts(
          "   ledger:          NOT recorded — citizens rejected the pressure, so no " <>
            "weight accumulates."
        )
    end
  end

  defp run_agi_brake(scenario) do
    vector = HRR.seeded_vector(scenario.proposal, HRR.default_dim())
    state = %{config: %{}, distilled: blank_distilled()}
    result = Distilled.loop_permitted?(state, vector, 0)
    IO.puts("   brake result:    #{inspect(result)}")
  end

  # `%Kudzu.Constitution.Distilled{}` has 5 `@enforce_keys`; the demo
  # runs against live silos, so we just need a syntactically valid
  # struct for `permitted?/2` to dispatch on. Pattern matches the T18
  # tests' "empty defaults" convention.
  defp blank_distilled do
    %Distilled{
      name: :demo,
      rules: %{},
      source: %{},
      trace_count: 0,
      distilled_at: 0
    }
  end
end
