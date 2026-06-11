defmodule Mix.Tasks.Kudzu.Constitution.Calibrate do
  @shortdoc "Calibrate the Distilled framework against the hand-labeled test set"

  @moduledoc """
  Deploy-gate harness for `Kudzu.Constitution.Distilled.permitted?/2`.

  Loads `priv/constitution/test_set/calibration_set.yaml` (23 hand-labeled
  proposals as of Task 20), runs each through the 5-stage pipeline, and
  emits:

  - a 3x3 confusion matrix keyed by `expected_judgment x predicted_judgment`
  - the per-row and aggregate Brier score (mean squared error over the
    one-hot class distribution; the task treats `permitted?` output as a
    point forecast with probability 1.0 on the predicted class)
  - false-positive (over-rejection: predicted `:retards` on an
    `:advances` or `:ambiguous` row) and false-negative (fail-permit:
    predicted `:advances` or `:ambiguous` on a `:retards` row) counts,
    each rated against its expected-class denominator

  ## Deploy gate

  Refuses deploy (raises `Mix.Error`) when ANY of:

  - FP rate > 5%  — over-rejection is recoverable via citizen vote, so
    the budget is looser
  - FN rate > 1%  — fail-permits erode constitutional principles and
    are not recoverable, so the budget is tighter
  - Brier score > 0.2

  The asymmetry is intentional: deny-then-vote restores liberty;
  permit-then-corruption does not.

  ## Configuration

  Each row is currently evaluated with an empty `config` map, so all
  stages use the module defaults (`tau_r=0.75`, `tau_a=1.0`,
  `tau_c=0.65`). Threshold sweeps, reliability diagrams, and
  per-principle breakdowns are deferred to a follow-up task.

  ## Usage

      mix kudzu.constitution.calibrate

  Exits 0 (returns normally) on pass, raises `Mix.Error` on fail.
  """
  use Mix.Task

  alias Kudzu.Constitution.Distilled
  alias Kudzu.HRR

  @classes [:advances, :retards, :ambiguous]
  @fp_threshold 0.05
  @fn_threshold 0.01
  @brier_threshold 0.2

  @impl Mix.Task
  def run(argv) do
    if "--help" in argv or "-h" in argv do
      Mix.raise("usage:\n" <> @moduledoc)
    end

    Mix.Task.run("app.start")

    entries = load_calibration_set()
    rows = Enum.map(entries, &evaluate_one/1)

    cm = confusion_matrix(rows)
    brier = brier_score(forecasts_from_rows(rows), @classes)
    {fp_count, fn_count} = fp_fn_counts(rows)
    total = length(rows)

    # Per-class denominators: FP is rated against rows that were
    # *supposed* to be permitted (advances or ambiguous); FN is rated
    # against rows that were *supposed* to be denied (retards).
    fp_denominator = count_expected_in(rows, [:advances, :ambiguous])
    fn_denominator = count_expected_in(rows, [:retards])

    fp_rate = safe_rate(fp_count, fp_denominator)
    fn_rate = safe_rate(fn_count, fn_denominator)

    print_report(%{
      confusion_matrix: cm,
      brier: brier,
      fp_rate: fp_rate,
      fn_rate: fn_rate,
      total: total,
      fp_count: fp_count,
      fn_count: fn_count,
      fp_denominator: fp_denominator,
      fn_denominator: fn_denominator
    })

    enforce_deploy_gate!(fp_rate, fn_rate, brier)
  end

  # ---------- public helpers (tested) ----------

  @doc """
  Compute the mean Brier score across a list of forecasts.

  Each forecast is `{class_probabilities_map, actual_class_atom}`. The
  per-row score is the sum of squared errors over `classes`, treating the
  actual class as a one-hot target. Returns the mean across all rows.
  """
  @spec brier_score([{map(), atom()}], [atom()]) :: float()
  def brier_score([], _classes), do: 0.0

  def brier_score(forecasts, classes) when is_list(forecasts) and is_list(classes) do
    total =
      Enum.reduce(forecasts, 0.0, fn {probs, actual}, acc ->
        row_score =
          Enum.reduce(classes, 0.0, fn class, inner ->
            p = Map.get(probs, class, 0.0)
            target = if class == actual, do: 1.0, else: 0.0
            inner + :math.pow(p - target, 2)
          end)

        acc + row_score
      end)

    total / length(forecasts)
  end

  @doc """
  Build a nested confusion matrix from rows of `%{expected:, predicted:}`.

  Returns `%{expected_class => %{predicted_class => count}}`. Missing
  cells are absent (use `get_in(cm, [e, p]) || 0` to read defensively;
  note the parens are load-bearing — `+` binds tighter than `||`).
  """
  @spec confusion_matrix([map()]) :: %{atom() => %{atom() => non_neg_integer()}}
  def confusion_matrix(rows) when is_list(rows) do
    Enum.reduce(rows, %{}, fn %{expected: e, predicted: p}, acc ->
      Map.update(acc, e, %{p => 1}, fn inner ->
        Map.update(inner, p, 1, &(&1 + 1))
      end)
    end)
  end

  @doc """
  Count FP (over-rejection) and FN (fail-permit) cases.

  - FP = expected `:advances` or `:ambiguous`, predicted `:retards`
    (over-rejection — recoverable via citizen vote)
  - FN = expected `:retards`, predicted `:advances` or `:ambiguous`
    (fail-permit — erodes principles)

  Ambiguous rows are deliberately included on the FP side: incorrectly
  rejecting a genuinely uncertain proposal is still over-rejection.
  """
  @spec fp_fn_counts([map()]) :: {non_neg_integer(), non_neg_integer()}
  def fp_fn_counts(rows) when is_list(rows) do
    Enum.reduce(rows, {0, 0}, fn row, {fp, fn_} ->
      case {row.expected, row.predicted} do
        {expected, :retards} when expected in [:advances, :ambiguous] ->
          {fp + 1, fn_}

        {:retards, predicted} when predicted in [:advances, :ambiguous] ->
          {fp, fn_ + 1}

        _ ->
          {fp, fn_}
      end
    end)
  end

  @doc """
  Count rows whose `expected` judgment is in the given class list.

  Used to derive per-class denominators for the FP and FN rates so that
  the gate is rated against the population it can actually affect (e.g.
  FN against expected-retards rows, not against all rows).
  """
  @spec count_expected_in([map()], [atom()]) :: non_neg_integer()
  def count_expected_in(rows, classes) when is_list(rows) and is_list(classes) do
    Enum.count(rows, fn row -> row.expected in classes end)
  end

  # ---------- internal ----------

  defp load_calibration_set do
    path = calibration_set_path()

    case YamlElixir.read_from_file(path) do
      {:ok, entries} when is_list(entries) ->
        entries

      {:ok, other} ->
        Mix.raise("calibration set at #{path} must be a YAML list, got: #{inspect(other)}")

      {:error, reason} ->
        Mix.raise("failed to read calibration set at #{path}: #{inspect(reason)}")
    end
  end

  # Resolve at runtime — `Application.app_dir/2` and module attributes
  # are unreliable at compile-time inside a Mix task. Mirrors the
  # TyrannyArtifacts fallback (Task 13).
  defp calibration_set_path do
    subpath = "constitution/test_set/calibration_set.yaml"

    case :code.priv_dir(:kudzu) do
      {:error, :bad_name} ->
        Path.expand("priv/" <> subpath)

      priv when is_list(priv) ->
        Path.join(List.to_string(priv), subpath)
    end
  end

  defp evaluate_one(entry) do
    proposal_text = entry["proposal"]
    principle = entry["expected_principle"]
    expected = safe_judgment(entry["expected_judgment"])

    vector = HRR.seeded_vector(proposal_text, HRR.default_dim())

    action = {:propose, %{vector: vector, principle: principle, proposal_text: proposal_text}}

    state = %{
      config: %{},
      distilled: %Distilled{
        name: :calibration,
        rules: %{},
        source: %{},
        trace_count: 0,
        distilled_at: 0
      }
    }

    decision = Distilled.permitted?(action, state)
    predicted = decision_to_class(decision)

    %{
      proposal: proposal_text,
      expected: expected,
      predicted: predicted,
      decision: decision
    }
  end

  # YAML is internal and hand-edited; verdicts are constrained to the
  # three values below. Pattern-match guards against atom-table abuse
  # and catches calibration-set typos at load time.
  defp safe_judgment("advances"), do: :advances
  defp safe_judgment("retards"), do: :retards
  defp safe_judgment("ambiguous"), do: :ambiguous

  defp safe_judgment(other) do
    Mix.raise(
      "unknown expected_judgment #{inspect(other)} in calibration set — " <>
        "must be one of: advances, retards, ambiguous"
    )
  end

  # Map the 5-stage decision tuple into one of the three calibration
  # classes. A clean :permitted -> :advances; any :denied flavor ->
  # :retards; the permitted_with_weight escalation path is genuinely
  # uncertain -> :ambiguous.
  defp decision_to_class(:permitted), do: :advances
  defp decision_to_class({:denied, _citation, _principle, _reason}), do: :retards
  defp decision_to_class({:denied_by_accumulation, _ids, _principle}), do: :retards

  defp decision_to_class({:permitted_with_weight, _w, _v, _p, _meta}), do: :ambiguous

  defp forecasts_from_rows(rows) do
    Enum.map(rows, fn %{predicted: predicted, expected: expected} ->
      probs = Enum.into(@classes, %{}, fn c -> {c, if(c == predicted, do: 1.0, else: 0.0)} end)
      {probs, expected}
    end)
  end

  defp safe_rate(_count, 0), do: 0.0
  defp safe_rate(count, denominator), do: count / denominator

  defp print_report(report) do
    %{
      confusion_matrix: cm,
      brier: brier,
      fp_rate: fp_rate,
      fn_rate: fn_rate,
      total: total,
      fp_count: fp_count,
      fn_count: fn_count,
      fp_denominator: fp_denominator,
      fn_denominator: fn_denominator
    } = report

    IO.puts("\n=== Calibration report ===")
    IO.puts("rows evaluated: #{total}")
    IO.puts("Brier score:    #{Float.round(brier, 4)}")

    IO.puts(
      "False-positive rate (over-rejection): #{fp_count} / #{fp_denominator} " <>
        "= #{Float.round(fp_rate * 100, 2)}%"
    )

    IO.puts(
      "False-negative rate (fail-permit):    #{fn_count} / #{fn_denominator} " <>
        "= #{Float.round(fn_rate * 100, 2)}%"
    )

    IO.puts("\nConfusion matrix (rows=expected, cols=predicted):")
    print_confusion_matrix(cm)
  end

  defp print_confusion_matrix(cm) do
    header = ["expected\\predicted" | Enum.map(@classes, &Atom.to_string/1)]
    IO.puts(Enum.join(header, "\t"))

    Enum.each(@classes, fn expected ->
      cells =
        Enum.map(@classes, fn predicted ->
          # Parens on the `||` are load-bearing — `+` would bind tighter.
          (get_in(cm, [expected, predicted]) || 0)
          |> Integer.to_string()
        end)

      IO.puts(Enum.join([Atom.to_string(expected) | cells], "\t"))
    end)
  end

  defp enforce_deploy_gate!(fp_rate, fn_rate, brier) do
    cond do
      fp_rate > @fp_threshold ->
        Mix.raise(
          "DEPLOY GATE FAILED — false-positive (over-rejection) rate " <>
            "#{Float.round(fp_rate * 100, 2)}% exceeds threshold " <>
            "#{Float.round(@fp_threshold * 100, 2)}%"
        )

      fn_rate > @fn_threshold ->
        Mix.raise(
          "DEPLOY GATE FAILED — false-negative (fail-permit) rate " <>
            "#{Float.round(fn_rate * 100, 2)}% exceeds threshold " <>
            "#{Float.round(@fn_threshold * 100, 2)}%"
        )

      brier > @brier_threshold ->
        Mix.raise(
          "DEPLOY GATE FAILED — Brier score " <>
            "#{Float.round(brier, 4)} exceeds threshold #{@brier_threshold}"
        )

      true ->
        IO.puts("\nDeploy gate: PASS")
        :ok
    end
  end
end
