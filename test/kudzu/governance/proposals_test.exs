defmodule Kudzu.Governance.ProposalsTest do
  @moduledoc """
  Proposal store: evaluation results are held exactly as `Distilled.explain/2`
  returned them, and a weighted proposal can be voted on once with its
  single-use governance token. Judges are injected, so no paid API is called.
  """
  # async: false — mutates the global proposal store and weight ledger.
  use ExUnit.Case, async: false

  # The fail-closed scenario logs a warning by design.
  @moduletag :capture_log

  alias Kudzu.Constitution.WeightLedger
  alias Kudzu.Governance.Proposals

  @assembly "Curfew on public assembly after 9pm"

  setup do
    :ok = WeightLedger.clear_for_test()
    :ok = Proposals.clear_for_test()
    :ok
  end

  defp weighted, do: fn _ -> {:ok, {:ambiguous, 0.55, "free_speech", "unclear", []}} end
  defp permit, do: fn _ -> {:ok, {:advances, 0.95, "free_speech", "fine", []}} end

  # Isolated, empty silos so the injected judge decides.
  defp config(judge) do
    salt = System.unique_integer([:positive])

    %{
      judge: judge,
      expertise_silo: "expertise:prop_#{salt}",
      rejection_silo: "rejection:prop_#{salt}"
    }
  end

  defp eval_weighted do
    {:ok, p} = Proposals.evaluate(@assembly, "free_assembly", config: config(weighted()))
    p
  end

  test "evaluate returns decision, five stages and an unspent token" do
    {:ok, p} =
      Proposals.evaluate(
        "Require a licence to publish criticism of officials",
        "free_speech",
        config: config(weighted())
      )

    assert {:permitted_with_weight, w, _, "free_speech", _} = p.decision
    assert_in_delta w, 0.45, 0.001
    assert length(p.stages) == 5 and p.token.spent == false and p.vote == nil
    assert p.id =~ ~r/^[0-9a-f]{16}$/
    assert p.token.id =~ ~r/^[0-9a-f]{16}$/
    assert p.token.id != p.id
    assert is_boolean(p.silos_empty)
    refute Map.has_key?(p, :vector)
    assert {:ok, ^p} = Proposals.get(p.id)
  end

  test "rejects blank text and unknown principles" do
    assert {:error, :empty_text} = Proposals.evaluate("   ", "free_speech", [])
    assert {:error, :unknown_principle} = Proposals.evaluate("Ban assemblies", "general", [])
  end

  test "text up to 20,000 characters is accepted; longer is refused before the judge runs" do
    text = String.duplicate("Ünïcödé 自由 ", 2_000) |> String.slice(0, 20_000)
    assert String.length(text) == 20_000 and byte_size(text) > 20_000
    assert {:ok, _} = Proposals.evaluate(text, "free_assembly", config: config(weighted()))

    test_pid = self()

    judge = fn _ ->
      send(test_pid, :judge_called)
      {:ok, {:ambiguous, 0.55, "free_speech", "unclear", []}}
    end

    assert {:error, :text_too_long} =
             Proposals.evaluate(text <> "x", "free_assembly", config: config(judge))

    refute_received :judge_called
  end

  test "yes vote writes one ledger entry and spends the token" do
    p = eval_weighted()
    {:ok, voted} = Proposals.vote(p.id, :yes)
    assert voted.vote == :yes and voted.token.spent
    assert [%{proposal_id: id, vote_outcome: :yes_with_weight}] = WeightLedger.entries()
    assert id == p.id
    assert {:ok, ^voted} = Proposals.get(p.id)
  end

  test "no vote spends the token without storing a ledger entry" do
    p = eval_weighted()
    {:ok, voted} = Proposals.vote(p.id, :no)
    assert voted.vote == :no and voted.token.spent
    assert WeightLedger.entries() == []
    assert {:error, :already_voted} = Proposals.vote(p.id, :yes)
  end

  test "second vote is refused and adds nothing" do
    p = eval_weighted()
    {:ok, _} = Proposals.vote(p.id, :yes)
    assert {:error, :already_voted} = Proposals.vote(p.id, :yes)
    assert length(WeightLedger.entries()) == 1
  end

  test "concurrent votes produce exactly one success" do
    p = eval_weighted()

    results =
      1..20
      |> Task.async_stream(fn _ -> Proposals.vote(p.id, :yes) end)
      |> Enum.map(&elem(&1, 1))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert length(WeightLedger.entries()) == 1
  end

  test "permitted, denied and cannot-evaluate proposals are not votable" do
    {:ok, p} =
      Proposals.evaluate("Protect peaceful protest", "free_assembly", config: config(permit()))

    assert p.decision == :permitted
    assert {:error, :not_votable} = Proposals.vote(p.id, :yes)

    {:ok, e} =
      Proposals.evaluate("Protect peaceful protest", "free_assembly",
        config: config(fn _ -> {:error, :refusal} end)
      )

    assert {:denied, "fail_closed:" <> _, _, _} = e.decision
    assert {:error, :not_votable} = Proposals.vote(e.id, :yes)
    assert WeightLedger.entries() == []
  end

  defmodule DownLedger do
    @moduledoc false
    def record(_id, _vector, _weight, _principle, _outcome), do: exit(:noproc)
  end

  defmodule RefusingLedger do
    @moduledoc false
    def record(_id, _vector, _weight, _principle, _outcome), do: {:error, :nope}
  end

  for {name, stub} <- [down: DownLedger, refusing: RefusingLedger] do
    test "#{name} ledger leaves the proposal unspent, the store alive and the vote retryable" do
      p = eval_weighted()
      pid = Process.whereis(Proposals)

      Application.put_env(:kudzu, :proposals_ledger, unquote(stub))
      on_exit(fn -> Application.delete_env(:kudzu, :proposals_ledger) end)

      assert {:error, :ledger_unavailable} = Proposals.vote(p.id, :yes)
      assert Process.whereis(Proposals) == pid
      assert {:ok, got} = Proposals.get(p.id)
      assert got.token.spent == false and got.vote == nil

      Application.delete_env(:kudzu, :proposals_ledger)
      assert {:ok, voted} = Proposals.vote(p.id, :yes)
      assert voted.token.spent and voted.vote == :yes
      assert [%{proposal_id: id}] = WeightLedger.entries()
      assert id == p.id
    end
  end

  test "unknown id" do
    assert {:error, :not_found} = Proposals.vote("0000000000000000", :yes)
    assert {:error, :not_found} = Proposals.get("0000000000000000")
  end
end
