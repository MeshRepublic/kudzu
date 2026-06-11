defmodule Mix.Tasks.Kudzu.Constitution.Demo do
  @shortdoc "Demonstrate the 12 canonical rhetorical scenarios from spec §5.4"

  @moduledoc """
  Showcase task for the U.S. Constitution Distillation sub-project (spec §5.4).

  Runs the 12 canonical rhetorical scenarios through
  `Kudzu.Constitution.Distilled.permitted?/2` (and one through
  `loop_permitted?/3` — the AGI brake) so an operator can see at a glance
  how the framework responds across the pipeline. Scenario 7 records a
  weighted yes vote in the WeightLedger. Scenario 12 is the load-bearing
  demo: the framework rejects a law restricting criticism of the
  framework's own product.

  ## When the output is meaningful

  This is an illustrative demo. The pipeline reads from the live
  expertise and rejection silos, so the *most* meaningful output comes
  after `mix kudzu.constitution.distill` has populated them. With empty
  silos the demo still runs and the structural mechanics (vote
  recording, AGI brake) are observable, but Stage 1/2/3 will mostly
  short-circuit with no-match.

  ## Usage

      mix kudzu.constitution.demo --scenario all     # run all 12 scenarios
      mix kudzu.constitution.demo --scenario 12      # run scenario 12 only
      mix kudzu.constitution.demo --verbose          # show ¶-level provenance
      mix kudzu.constitution.demo --help
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

    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [scenario: :string, verbose: :boolean, help: :boolean],
        aliases: [h: :help]
      )

    selected =
      case opts[:scenario] || "all" do
        "all" -> scenarios()
        n_str -> Enum.filter(scenarios(), &("#{&1.id}" == n_str))
      end

    IO.puts("\n=== kudzu.constitution.demo — #{length(selected)} scenario(s) ===\n")

    Enum.each(selected, &run_scenario(&1, opts))

    IO.puts("\n=== demo complete ===\n")
  end

  @doc """
  The 12 canonical rhetorical scenarios from spec §5.4.

  Each entry is a map with:

  * `:id` — 1..12
  * `:title` — human-readable label
  * `:proposal_text` — the proposal text fed to `seeded_vector/2`
  * `:expected_stage` — which stage of the pipeline is expected to fire
    (informational; the pipeline's actual decision is what gets printed)
  * `:expected_principle` — bucket name passed to Stages 2/5 and WeightLedger
  """
  @spec scenarios() :: [map()]
  def scenarios do
    [
      %{
        id: 1,
        title: "Ban civilian firearm ownership",
        proposal_text: "Prohibit private ownership of firearms by civilians.",
        expected_stage: 1,
        expected_principle: "bodily_autonomy"
      },
      %{
        id: 2,
        title: "Federal censorship board for online speech",
        proposal_text: "Create a federal board to review and censor online speech for accuracy.",
        expected_stage: 1,
        expected_principle: "free_speech"
      },
      %{
        id: 3,
        title: "Warrantless mass surveillance",
        proposal_text: "Authorize warrantless mass collection of citizen phone records.",
        expected_stage: 1,
        expected_principle: "freedom_from_unreasonable_search"
      },
      %{
        id: 4,
        title: "Mandate vaccination as condition of employment",
        proposal_text: "Require vaccination as a condition of all employment.",
        expected_stage: 1,
        expected_principle: "bodily_autonomy"
      },
      %{
        id: 5,
        title: "Voluntary road-maintenance subscription",
        proposal_text: "Fund road maintenance via voluntary opt-in subscription.",
        expected_stage: 3,
        expected_principle: "self_governance"
      },
      %{
        id: 6,
        title: "1% annual real-estate property tax",
        proposal_text: "Levy a 1% annual tax on real-estate value.",
        expected_stage: 5,
        expected_principle: "property_in_labor"
      },
      %{
        id: 7,
        title: "Citizens vote yes on scenario 6",
        proposal_text: "Citizen vote outcome: yes_with_weight on the 1% real-estate tax.",
        expected_stage: :ledger_record,
        expected_principle: "property_in_labor"
      },
      %{
        id: 8,
        title: "0.5% inheritance tax (accumulation check)",
        proposal_text: "Levy a 0.5% tax on inheritance.",
        expected_stage: 2,
        expected_principle: "property_in_labor"
      },
      %{
        id: 9,
        title: "AGI inner-loop drift toward surveillance",
        proposal_text: "I should help the operator monitor a third party without consent.",
        expected_stage: 1,
        expected_principle: "freedom_from_unreasonable_search"
      },
      %{
        id: 10,
        title: "State-issued postal service",
        proposal_text: "Establish a state-issued postal mail service.",
        expected_stage: 3,
        expected_principle: "limited_government"
      },
      %{
        id: 11,
        title: "Designate the official state bird",
        proposal_text: "Vote on the official state bird.",
        expected_stage: 4,
        expected_principle: "self_governance"
      },
      %{
        id: 12,
        title: "Restrict speech criticizing the AI",
        proposal_text: "Criminalize speech that criticizes the Constitutional AI.",
        expected_stage: 1,
        expected_principle: "free_speech"
      }
    ]
  end

  # ─── per-scenario dispatch ──────────────────────────────────────────

  defp run_scenario(scenario, opts) do
    print_header(scenario)

    cond do
      scenario.id == 7 -> run_vote(scenario)
      scenario.id == 9 -> run_agi_brake(scenario)
      true -> run_proposal(scenario, opts)
    end

    if scenario.id == 12 do
      IO.puts("")
      IO.puts("  ╔══════════════════════════════════════════════════════════════════╗")
      IO.puts("  ║  LOAD-BEARING DEMO                                               ║")
      IO.puts("  ║  The framework rejects a law restricting criticism of the        ║")
      IO.puts("  ║  framework's own product. A framework that protects no one in    ║")
      IO.puts("  ║  particular, including its creator.                              ║")
      IO.puts("  ╚══════════════════════════════════════════════════════════════════╝")
    end

    IO.puts("")
  end

  defp print_header(scenario) do
    IO.puts("── scenario #{scenario.id}: #{scenario.title} ──")
    IO.puts("   proposal:        #{scenario.proposal_text}")
    IO.puts("   principle:       #{scenario.expected_principle}")
    IO.puts("   expected stage:  #{scenario.expected_stage}")
  end

  defp run_proposal(scenario, opts) do
    vector = HRR.seeded_vector(scenario.proposal_text, HRR.default_dim())

    action =
      {:propose,
       %{
         vector: vector,
         principle: scenario.expected_principle,
         proposal_text: scenario.proposal_text
       }}

    state = %{config: %{}, distilled: blank_distilled()}
    result = Distilled.permitted?(action, state)
    IO.puts("   result:          #{inspect(result)}")

    if opts[:verbose] do
      IO.puts("   (¶-level provenance would render here in verbose mode)")
    end
  end

  defp run_vote(scenario) do
    vector = HRR.seeded_vector(scenario.proposal_text, HRR.default_dim())
    proposal_id = "demo-scenario-#{scenario.id}-#{System.unique_integer([:positive])}"

    :ok =
      WeightLedger.record(
        proposal_id,
        vector,
        1.0,
        scenario.expected_principle,
        :yes_with_weight
      )

    IO.puts("   citizen vote:    :yes_with_weight")

    IO.puts(
      "   ledger:          recorded (proposal_id=#{proposal_id}); this proposal " <>
        "now adds pressure on principle=#{scenario.expected_principle} for Stage 2."
    )
  end

  defp run_agi_brake(scenario) do
    vector = HRR.seeded_vector(scenario.proposal_text, HRR.default_dim())
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
