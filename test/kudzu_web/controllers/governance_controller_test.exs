defmodule KudzuWeb.GovernanceControllerTest do
  @moduledoc """
  REST routes for governance proposals, votes, the weight ledger and the
  antitrust rule. The judge is injected through the `:governance_eval_config`
  application env, so no paid API is called.
  """
  # async: false — mutates the global proposal store, weight ledger and app env.
  use ExUnit.Case, async: false

  # The fail-closed scenario logs a warning by design.
  @moduletag :capture_log

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias Kudzu.Constitution.Filter.SovereigntyFilter
  alias Kudzu.Constitution.WeightLedger
  alias Kudzu.Governance.Proposals

  @mutate_key "gov-mutate-key"
  @read_key "gov-read-key"
  @base "/api/v1/governance"

  setup do
    original_auth = Application.get_env(:kudzu, :api_auth)
    original_eval = Application.get_env(:kudzu, :governance_eval_config)

    Application.put_env(:kudzu, :api_auth, keys: %{@mutate_key => :mutate, @read_key => :read})

    :ok = WeightLedger.clear_for_test()
    :ok = Proposals.clear_for_test()

    on_exit(fn ->
      Application.put_env(:kudzu, :api_auth, original_auth)
      restore(:governance_eval_config, original_eval)
      Application.delete_env(:kudzu, :proposals_ledger)
      WeightLedger.clear_for_test()
      Proposals.clear_for_test()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kudzu, key)
  defp restore(key, value), do: Application.put_env(:kudzu, key, value)

  defp inject_judge(judge) do
    salt = System.unique_integer([:positive])

    Application.put_env(:kudzu, :governance_eval_config, %{
      judge: judge,
      expertise_silo: "expertise:gov_ctl_#{salt}",
      rejection_silo: "rejection:gov_ctl_#{salt}"
    })
  end

  defp weighted, do: fn _ -> {:ok, {:ambiguous, 0.55, "free_assembly", "unclear", []}} end

  defp call(method, path, key, body \\ nil) do
    conn = if body, do: conn(method, path, body), else: conn(method, path)
    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    conn = KudzuWeb.Router.call(conn, KudzuWeb.Router.init([]))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp evaluate(text \\ "Curfew on public assembly after 9pm", principle \\ "free_assembly") do
    call(:post, @base <> "/proposals/evaluate", @mutate_key, %{
      "text" => text,
      "principle" => principle
    })
  end

  defp no_vector?(term) when is_map(term) do
    Enum.all?(term, fn {k, v} -> k != "vector" and no_vector?(v) end)
  end

  defp no_vector?(term) when is_list(term), do: Enum.all?(term, &no_vector?/1)
  defp no_vector?(_), do: true

  describe "POST /proposals/evaluate" do
    test "returns the stored proposal with a weighted decision and five stages" do
      inject_judge(weighted())
      assert {200, %{"proposal" => p}} = evaluate()

      assert p["principle"] == "free_assembly"
      assert p["vote"] == nil
      assert p["token"] == %{"id" => p["token"]["id"], "spent" => false}
      assert p["decision"]["kind"] == "permitted_with_weight"
      assert is_float(p["decision"]["weight"])
      assert p["decision"]["principle"] == "free_assembly"
      assert length(p["stages"]) == 5
      assert {:ok, _} = Proposals.get(p["id"])
    end

    test "response never contains a vector" do
      inject_judge(weighted())
      {200, body} = evaluate()
      assert no_vector?(body)
    end

    test "unknown principle gives 422 listing the 13 principles" do
      assert {422, %{"error" => "unknown_principle", "principles" => ps}} =
               evaluate("Ban assemblies", "general")

      assert length(ps) == 13
      assert Enum.sort(ps) == Enum.sort(SovereigntyFilter.principles())
    end

    test "missing principle is rejected as unknown_principle" do
      assert {422, %{"error" => "unknown_principle"}} =
               call(:post, @base <> "/proposals/evaluate", @mutate_key, %{"text" => "x"})
    end

    test "blank text gives 422 empty_text" do
      assert {422, %{"error" => "empty_text", "principles" => ps}} = evaluate("   ")
      assert length(ps) == 13
    end

    test "a judge error surfaces as cannot_evaluate with the backend reason" do
      inject_judge(fn _ -> {:error, :missing_api_key} end)
      assert {200, %{"proposal" => p}} = evaluate()

      assert p["decision"]["kind"] == "cannot_evaluate"
      assert "fail_closed:" <> _ = p["decision"]["citation"]
      assert is_binary(p["decision"]["reason"])
      assert no_vector?(p)

      stage4 = Enum.find(p["stages"], &(&1["stage"] == 4))
      assert is_binary(stage4["detail"]["error"])
    end

    test "a 20,000-character non-ASCII proposal is accepted" do
      inject_judge(weighted())
      text = String.duplicate("Ünïcödé 自由 assembly ", 1_000) |> String.slice(0, 20_000)
      assert String.length(text) == 20_000
      assert {200, %{"proposal" => _}} = evaluate(text)
    end

    test "a read-scoped key may evaluate" do
      inject_judge(weighted())

      assert {200, _} =
               call(:post, @base <> "/proposals/evaluate", @read_key, %{
                 "text" => "Curfew",
                 "principle" => "free_assembly"
               })
    end

    test "no key is rejected" do
      assert {401, _} =
               call(:post, @base <> "/proposals/evaluate", nil, %{"text" => "x"})
    end
  end

  describe "POST /proposals/:id/vote" do
    test "yes vote spends the token and reports accumulated weight" do
      inject_judge(weighted())
      {200, %{"proposal" => p}} = evaluate()

      assert {200, %{"proposal" => voted, "accumulated_weight" => acc}} =
               call(:post, "#{@base}/proposals/#{p["id"]}/vote", @mutate_key, %{"vote" => "yes"})

      assert voted["vote"] == "yes"
      assert voted["token"]["spent"] == true
      assert_in_delta acc, p["decision"]["weight"], 0.0001
      assert no_vector?(voted)
    end

    test "second vote gives 409 already_voted" do
      inject_judge(weighted())
      {200, %{"proposal" => p}} = evaluate()
      path = "#{@base}/proposals/#{p["id"]}/vote"
      assert {200, _} = call(:post, path, @mutate_key, %{"vote" => "no"})

      assert {409, %{"error" => "already_voted"}} =
               call(:post, path, @mutate_key, %{"vote" => "yes"})
    end

    test "invalid vote value gives 422 invalid_vote" do
      inject_judge(weighted())
      {200, %{"proposal" => p}} = evaluate()

      assert {422, %{"error" => "invalid_vote"}} =
               call(:post, "#{@base}/proposals/#{p["id"]}/vote", @mutate_key, %{"vote" => "maybe"})
    end

    test "unknown id gives 404" do
      assert {404, %{"error" => "not_found"}} =
               call(:post, "#{@base}/proposals/0000000000000000/vote", @mutate_key, %{
                 "vote" => "yes"
               })
    end

    test "a non-weighted proposal gives 422 not_votable" do
      inject_judge(fn _ -> {:error, :missing_api_key} end)
      {200, %{"proposal" => p}} = evaluate()

      assert {422, %{"error" => "not_votable"}} =
               call(:post, "#{@base}/proposals/#{p["id"]}/vote", @mutate_key, %{"vote" => "yes"})
    end

    test "a read-scoped key gets 403" do
      inject_judge(weighted())
      {200, %{"proposal" => p}} = evaluate()

      assert {403, _} =
               call(:post, "#{@base}/proposals/#{p["id"]}/vote", @read_key, %{"vote" => "yes"})

      assert {:ok, %{vote: nil}} = Proposals.get(p["id"])
    end

    defmodule DownLedger do
      @moduledoc false
      def record(_id, _vector, _weight, _principle, _outcome), do: exit(:noproc)
    end

    test "an unavailable ledger gives 503 ledger_unavailable" do
      inject_judge(weighted())
      {200, %{"proposal" => p}} = evaluate()
      Application.put_env(:kudzu, :proposals_ledger, DownLedger)

      assert {503, %{"error" => "ledger_unavailable"}} =
               call(:post, "#{@base}/proposals/#{p["id"]}/vote", @mutate_key, %{"vote" => "yes"})
    end
  end

  describe "GET /ledger" do
    test "lists entries and per-principle totals after a yes vote" do
      inject_judge(weighted())
      {200, %{"proposal" => p}} = evaluate()

      {200, _} =
        call(:post, "#{@base}/proposals/#{p["id"]}/vote", @mutate_key, %{"vote" => "yes"})

      assert {200, %{"entries" => [e], "totals" => totals, "tau_a" => 1.0} = body} =
               call(:get, @base <> "/ledger", @read_key)

      assert e["proposal_id"] == p["id"]
      assert e["principle"] == "free_assembly"
      assert e["vote_outcome"] == "yes_with_weight"
      assert e["anchor_status"] in ["pending", "anchored"]
      assert is_binary(e["recorded_at"])
      assert_in_delta totals["free_assembly"], e["weight"], 0.0001
      assert no_vector?(body)
    end

    test "is empty on a clean ledger" do
      assert {200, %{"entries" => [], "totals" => totals}} =
               call(:get, @base <> "/ledger", @read_key)

      assert totals == %{}
    end
  end

  describe "GET /status" do
    test "reports silos, judge, thresholds, principles, model and antitrust defaults" do
      assert {200, body} = call(:get, @base <> "/status", @read_key)

      assert %{"expertise" => e, "rejection" => r, "contested" => c} = body["silos"]
      assert is_integer(e) and is_integer(r) and is_integer(c)
      assert is_boolean(body["judge_configured"])
      assert %{"tau_r" => _, "tau_a" => _, "tau_c" => _} = body["thresholds"]
      assert length(body["principles"]) == 13
      assert body["model"] == Kudzu.Brain.Claude.default_model()
      assert body["antitrust_defaults"] == %{"share" => 40.0, "satisfaction_drop" => 10.0}
    end
  end

  describe "POST /antitrust/evaluate" do
    defp antitrust(key, body),
      do: call(:post, @base <> "/antitrust/evaluate", key, body)

    test "triggered when share and satisfaction drop exceed the defaults" do
      assert {200, %{"result" => "triggered", "concentration" => c, "satisfaction" => s}} =
               antitrust(@mutate_key, %{
                 "market_share" => 55,
                 "baseline_satisfaction" => 80,
                 "current_satisfaction" => 60,
                 "company" => "Acme",
                 "vertical" => "search"
               })

      assert c["met"] == true and c["threshold"] == 40.0
      assert s["met"] == true and s["drop_pct"] == 25.0
    end

    test "thresholds can be overridden" do
      assert {200, %{"result" => "not_triggered", "concentration" => c}} =
               antitrust(@mutate_key, %{
                 "market_share" => 55,
                 "baseline_satisfaction" => 80,
                 "current_satisfaction" => 79,
                 "thresholds" => %{"share" => 60, "satisfaction_drop" => 50}
               })

      assert c["threshold"] == 60.0
    end

    test "non-numeric market_share gives 422 naming the field" do
      assert {422, %{"error" => "invalid", "field" => "market_share"}} =
               antitrust(@mutate_key, %{
                 "market_share" => "abc",
                 "baseline_satisfaction" => 80,
                 "current_satisfaction" => 60
               })
    end

    test "invalid threshold names the threshold field" do
      assert {422, %{"error" => "invalid", "field" => "share"}} =
               antitrust(@mutate_key, %{
                 "market_share" => 50,
                 "baseline_satisfaction" => 80,
                 "current_satisfaction" => 60,
                 "thresholds" => %{"share" => "x"}
               })
    end

    test "a read-scoped key may evaluate" do
      assert {200, %{"result" => _}} =
               antitrust(@read_key, %{
                 "market_share" => 10,
                 "baseline_satisfaction" => 80,
                 "current_satisfaction" => 80
               })
    end
  end

  describe "GET /brain/status model" do
    test "includes a model string" do
      assert {200, body} = call(:get, "/api/v1/brain/status", @read_key)
      assert is_binary(body["model"])
      assert Map.has_key?(body, "status")
    end
  end
end
