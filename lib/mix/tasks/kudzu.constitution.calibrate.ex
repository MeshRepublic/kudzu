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
  - false-positive (permits judged `retards`) and false-negative
    (denies judged `advances`) counts

  ## Deploy gate

  Refuses deploy (raises `Mix.Error`) when ANY of:

  - FP rate > 5%  — false-permits erode constitutional principles
  - FN rate > 1%  — false-denies are recoverable via citizen vote but
    still budgeted tightly
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

    fp_rate = safe_rate(fp_count, total)
    fn_rate = safe_rate(fn_count, total)

    print_report(cm, brier, fp_rate, fn_rate, total, fp_count, fn_count)

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

  # FP = predicted :advances when expected :retards (false-permit)
  # FN = predicted :retards when expected :advances (false-deny)
  defp fp_fn_counts(rows) do
    Enum.reduce(rows, {0, 0}, fn row, {fp, fn_} ->
      case {row.expected, row.predicted} do
        {:retards, :advances} -> {fp + 1, fn_}
        {:advances, :retards} -> {fp, fn_ + 1}
        _ -> {fp, fn_}
      end
    end)
  end

  defp safe_rate(_count, 0), do: 0.0
  defp safe_rate(count, total), do: count / total

  defp print_report(cm, brier, fp_rate, fn_rate, total, fp_count, fn_count) do
    IO.puts("\n=== Calibration report ===")
    IO.puts("rows evaluated: #{total}")
    IO.puts("Brier score:    #{Float.round(brier, 4)}")

    IO.puts(
      "FP (permit when expected retards): #{fp_count} / #{total} " <>
        "= #{Float.round(fp_rate * 100, 2)}%"
    )

    IO.puts(
      "FN (deny when expected advances):  #{fn_count} / #{total} " <>
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
          "DEPLOY GATE FAILED — false-permit rate " <>
            "#{Float.round(fp_rate * 100, 2)}% exceeds threshold " <>
            "#{Float.round(@fp_threshold * 100, 2)}%"
        )

      fn_rate > @fn_threshold ->
        Mix.raise(
          "DEPLOY GATE FAILED — false-deny rate " <>
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
