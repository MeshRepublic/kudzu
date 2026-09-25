defmodule Kudzu.Constitution.DistilledFailClosedTest do
  @moduledoc """
  Constitution enforcement fails closed: when the AI Judge cannot rule
  (no API key, or an error), Stage 4 denies with an audit record — it
  never permits an unjudged proposal.
  """
  # async: false — mutates ANTHROPIC_API_KEY and the global WeightLedger.
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.{Distilled, WeightLedger}
  alias Kudzu.Constitution.Vectors

  setup do
    :ok = WeightLedger.clear_for_test()
    salt = :rand.uniform(999_999)
    rejection = "rejection:fail_closed_test_#{salt}"
    expertise = "expertise:fail_closed_test_#{salt}"
    {:ok, _} = Kudzu.Silo.create(rejection, %{})
    {:ok, _} = Kudzu.Silo.create(expertise, %{})

    config = %{rejection_silo: rejection, expertise_silo: expertise, tau_r: 0.75, tau_a: 1.0}

    state = %{
      distilled: %Distilled{name: "t", rules: %{}, source: %{}, trace_count: 0, distilled_at: 0},
      config: config
    }

    action =
      {:propose,
       %{
         vector: Vectors.encode_text("designate an official state bird"),
         principle: "self_governance",
         proposal_text: "designate an official state bird"
       }}

    %{state: state, action: action}
  end

  defp with_judge(state, judge), do: put_in(state, [:config, :judge], judge)

  test "no API key: the default AIJudge path denies with judge_not_configured",
       %{state: state, action: action} do
    original = System.get_env("ANTHROPIC_API_KEY")
    System.delete_env("ANTHROPIC_API_KEY")

    on_exit(fn -> if original, do: System.put_env("ANTHROPIC_API_KEY", original) end)

    # No :judge override — exercises the real Kudzu.Constitution.AIJudge,
    # which returns {:error, :missing_api_key} without making any call.
    assert {:denied, "fail_closed:judge_not_configured", "self_governance", reason} =
             Distilled.permitted?(action, state)

    assert reason =~ "not configured"
  end

  test "judge error: denies with judge_unavailable", %{state: state, action: action} do
    state = with_judge(state, fn _ -> {:error, :all_samples_failed} end)

    assert {:denied, "fail_closed:judge_unavailable", "self_governance", reason} =
             Distilled.permitted?(action, state)

    assert reason =~ "all_samples_failed"
  end

  test "a fail-closed denial is audited via telemetry", %{state: state, action: action} do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "fail-closed-test-#{inspect(ref)}",
      [:kudzu, :constitution, :fail_closed],
      fn _event, measurements, metadata, _ -> send(parent, {ref, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("fail-closed-test-#{inspect(ref)}") end)

    state = with_judge(state, fn _ -> {:error, :missing_api_key} end)
    assert {:denied, _, _, _} = Distilled.permitted?(action, state)

    assert_receive {^ref, %{count: 1}, metadata}
    assert metadata.citation == "fail_closed:judge_not_configured"
    assert metadata.principle == "self_governance"
    assert metadata.proposal == "designate an official state bird"
    assert "audit-fail-closed-" <> _ = metadata.id
  end

  test "never :permitted or :permitted_with_weight when the judge cannot rule",
       %{state: state, action: action} do
    for reason <- [:missing_api_key, :timeout, :all_samples_failed, {:http, 500}] do
      result = Distilled.permitted?(action, with_judge(state, fn _ -> {:error, reason} end))
      assert match?({:denied, "fail_closed:" <> _, _, _}, result), inspect({reason, result})
    end
  end

  test "a judge that can rule still decides: advances permits", %{state: state, action: action} do
    judge = fn _ -> {:ok, {:advances, 0.9, "self_governance", "harmless", []}} end
    assert Distilled.permitted?(action, with_judge(state, judge)) == :permitted
  end

  test "a judge that can rule still decides: ambiguous escalates with weight",
       %{state: state, action: action} do
    judge = fn _ -> {:ok, {:ambiguous, 0.4, "self_governance", "unclear", []}} end

    assert {:permitted_with_weight, weight, _, "self_governance", _} =
             Distilled.permitted?(action, with_judge(state, judge))

    assert_in_delta weight, 0.6, 1.0e-9
  end
end
