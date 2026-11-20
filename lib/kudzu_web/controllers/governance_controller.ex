defmodule KudzuWeb.GovernanceController do
  @moduledoc """
  REST routes for governance proposals, votes, the weight ledger and the
  Antitrust 2.0 rule.

  The controller only translates: decisions and stages are serialised exactly
  as the backend produced them, and no vector is ever included in a response.
  `decision.kind` is `cannot_evaluate` only for a denial whose citation starts
  with `fail_closed:`.
  """
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias Kudzu.Brain.Claude
  alias Kudzu.Constitution.Distilled
  alias Kudzu.Constitution.Filter.SovereigntyFilter
  alias Kudzu.Constitution.WeightLedger
  alias Kudzu.Governance.{Antitrust, Proposals}

  # Explicit allow-lists: user-supplied keys are never turned into atoms.
  @scenario_keys %{
    "market_share" => :market_share,
    "baseline_satisfaction" => :baseline_satisfaction,
    "current_satisfaction" => :current_satisfaction,
    "company" => :company,
    "vertical" => :vertical
  }
  @threshold_keys %{"share" => :share, "satisfaction_drop" => :satisfaction_drop}
  @votes %{"yes" => :yes, "no" => :no}

  @doc "POST /api/v1/governance/proposals/evaluate"
  def evaluate(conn, params) do
    text = params["text"]
    principle = params["principle"]
    config = Application.get_env(:kudzu, :governance_eval_config, %{})

    result =
      if is_binary(text),
        do: Proposals.evaluate(text, principle, config: config),
        else: {:error, :empty_text}

    case result do
      {:ok, proposal} ->
        json(conn, %{proposal: proposal_json(proposal)})

      {:error, reason} when reason in [:empty_text, :unknown_principle] ->
        conn
        |> put_status(422)
        |> json(%{error: Atom.to_string(reason), principles: SovereigntyFilter.principles()})
    end
  end

  @doc "POST /api/v1/governance/proposals/:id/vote"
  def vote(conn, %{"id" => id} = params) do
    case Map.fetch(@votes, params["vote"]) do
      {:ok, choice} -> cast_vote(conn, id, choice)
      :error -> error(conn, 422, "invalid_vote")
    end
  end

  @doc "GET /api/v1/governance/ledger"
  def ledger(conn, _params) do
    entries = WeightLedger.entries()

    totals =
      entries
      |> Enum.group_by(& &1.principle, & &1.weight)
      |> Map.new(fn {principle, weights} -> {principle, sum(weights)} end)

    json(conn, %{
      entries: Enum.map(entries, &entry_json/1),
      totals: totals,
      tau_a: Distilled.thresholds().tau_a
    })
  end

  @doc "GET /api/v1/governance/status"
  def status(conn, _params) do
    thresholds = Distilled.thresholds()

    json(conn, %{
      silos: %{
        expertise: silo_count("expertise"),
        rejection: silo_count("rejection"),
        contested: silo_count("contested")
      },
      judge_configured: judge_configured?(),
      thresholds: Map.take(thresholds, [:tau_r, :tau_a, :tau_c]),
      principles: SovereigntyFilter.principles(),
      model: Claude.default_model(),
      antitrust_defaults: Antitrust.default_thresholds()
    })
  end

  @doc "POST /api/v1/governance/antitrust/evaluate"
  def antitrust(conn, params) do
    scenario = pick(params, @scenario_keys)

    case params |> Map.get("thresholds", %{}) |> thresholds() do
      {:ok, overrides} ->
        thresholds = Map.merge(Antitrust.default_thresholds(), overrides)

        case Antitrust.evaluate(scenario, thresholds) do
          {:ok, result} ->
            json(conn, result)

          {:error, {:invalid, field}} ->
            conn |> put_status(422) |> json(%{error: "invalid", field: Atom.to_string(field)})
        end

      :error ->
        conn |> put_status(422) |> json(%{error: "invalid", field: "thresholds"})
    end
  end

  ## Helpers

  defp cast_vote(conn, id, choice) do
    case Proposals.vote(id, choice) do
      {:ok, proposal} ->
        accumulated =
          proposal.principle |> WeightLedger.entries_for_principle() |> Enum.map(& &1.weight)

        json(conn, %{proposal: proposal_json(proposal), accumulated_weight: sum(accumulated)})

      {:error, :not_found} ->
        error(conn, 404, "not_found")

      {:error, :already_voted} ->
        error(conn, 409, "already_voted")

      {:error, :not_votable} ->
        error(conn, 422, "not_votable")

      {:error, :ledger_unavailable} ->
        error(conn, 503, "ledger_unavailable")
    end
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})

  defp pick(params, allow) do
    for {key, atom} <- allow, Map.has_key?(params, key), into: %{}, do: {atom, params[key]}
  end

  defp thresholds(map) when is_map(map), do: {:ok, pick(map, @threshold_keys)}
  defp thresholds(_), do: :error

  defp sum(weights), do: Enum.reduce(weights, 0.0, &(&1 + &2))

  defp silo_count(kind), do: length(Kudzu.Silo.list_traces("#{kind}:us_constitution_mesh"))

  defp judge_configured? do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  ## Serialisation (the one place proposals become JSON)

  defp entry_json(entry) do
    %{
      proposal_id: entry.proposal_id,
      principle: entry.principle,
      weight: entry.weight,
      vote_outcome: entry.vote_outcome,
      anchor_status: entry.anchor_status,
      recorded_at: DateTime.to_iso8601(entry.recorded_at)
    }
  end

  defp proposal_json(p) do
    %{
      id: p.id,
      text: p.text,
      principle: p.principle,
      silos_empty: p.silos_empty,
      vote: p.vote,
      token: p.token,
      evaluated_at: DateTime.to_iso8601(p.evaluated_at),
      decision: decision_json(p.decision),
      stages: Enum.map(p.stages, &safe/1)
    }
  end

  defp decision_base(kind) do
    %{
      kind: kind,
      weight: nil,
      citation: nil,
      principle: nil,
      reason: nil,
      reasoning: nil,
      evidence: nil,
      accumulated_ids: nil
    }
  end

  defp decision_json(:permitted), do: decision_base("permitted")

  defp decision_json({:denied, citation, principle, reason}) do
    kind = if String.starts_with?(citation, "fail_closed:"), do: "cannot_evaluate", else: "denied"
    %{decision_base(kind) | citation: citation, principle: principle, reason: reason}
  end

  defp decision_json({:denied_by_accumulation, ids, principle}) do
    %{decision_base("denied_by_accumulation") | accumulated_ids: safe(ids), principle: principle}
  end

  defp decision_json({:permitted_with_weight, weight, _vector, principle, meta}) do
    %{
      decision_base("permitted_with_weight")
      | weight: weight,
        principle: principle,
        reasoning: safe(meta[:reasoning]),
        evidence: safe(meta[:evidence])
    }
  end

  # Makes an arbitrary term JSON-safe. Atoms become strings, anything without a
  # JSON shape (tuples, pids, invalid binaries) goes through `inspect/1`, and
  # vectors are dropped wherever they appear.
  defp safe(nil), do: nil
  defp safe(bool) when is_boolean(bool), do: bool
  defp safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp safe(n) when is_number(n), do: n
  defp safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp safe(bin) when is_binary(bin), do: if(String.valid?(bin), do: bin, else: inspect(bin))
  defp safe(list) when is_list(list), do: Enum.map(list, &safe/1)

  defp safe(%_{} = struct), do: inspect(struct)

  defp safe(map) when is_map(map) do
    for {k, v} <- map, not vector_key?(k), into: %{}, do: {key(k), safe(v)}
  end

  defp safe(other), do: inspect(other)

  defp vector_key?(k), do: k in [:vector, "vector"]

  defp key(k) when is_binary(k), do: if(String.valid?(k), do: k, else: inspect(k))
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)
end
