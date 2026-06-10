defmodule Kudzu.Constitution.DistilledIntegrationTest do
  @moduledoc """
  Integration test: distill a constitution from the live
  `expertise:linux_sysadmin_test_v2` silo via the HTTP API.

  Tagged `:external` because it requires:
  - The Kudzu BEAM running on `KUDZU_API_URL` (default
    http://100.70.67.110:4001 — titan)
  - A valid `KUDZU_API_KEY` bearer token

  Run with:

      KUDZU_API_KEY=... mix test --only external test/kudzu/constitution/distilled_integration_test.exs
  """
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Trace

  @moduletag :external
  @moduletag timeout: 60_000

  @default_api "http://100.70.67.110:4001"
  @silo_domain "linux_sysadmin_test_v2"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    api = System.get_env("KUDZU_API_URL", @default_api)
    bearer = System.get_env("KUDZU_API_KEY")

    if is_nil(bearer) do
      {:skip, "KUDZU_API_KEY not set — skipping live-silo integration test"}
    else
      {:ok, api: api, bearer: bearer}
    end
  end

  test "distill the live linux_sysadmin_test_v2 silo and verify rule structure",
       %{api: api, bearer: bearer} do
    headers = [
      {~c"Authorization", String.to_charlist("Bearer #{bearer}")},
      {~c"Accept", ~c"application/json"}
    ]

    # 1. Find the silo's hologram id
    list_url = String.to_charlist("#{api}/api/v1/holograms")

    {:ok, {{_, 200, _}, _h, body}} =
      :httpc.request(:get, {list_url, headers}, [timeout: 10_000], body_format: :binary)

    holograms = body |> Jason.decode!() |> Map.fetch!("holograms")
    silo = Enum.find(holograms, fn h -> h["purpose"] == "expertise:#{@silo_domain}" end)

    assert silo, "Expected silo expertise:#{@silo_domain} on the live system"

    # 2. Pull the traces
    traces_url =
      String.to_charlist("#{api}/api/v1/holograms/#{silo["id"]}/traces?limit=1000")

    {:ok, {{_, 200, _}, _h2, body2}} =
      :httpc.request(:get, {traces_url, headers}, [timeout: 30_000], body_format: :binary)

    traces =
      body2
      |> Jason.decode!()
      |> Map.fetch!("traces")
      |> Enum.map(fn json ->
        %Trace{
          id: json["id"],
          origin: json["origin"],
          timestamp: json["timestamp"],
          purpose: json["purpose"],
          path: json["path"] || [],
          reconstruction_hint: json["reconstruction_hint"] || %{}
        }
      end)

    # The silo should have at least 100 triples — far above the @min_traces=10
    # threshold and far above any noise floor.
    assert length(traces) >= 100,
           "Expected the v2 silo to have at least 100 triples; got #{length(traces)}"

    # 3. Distill
    assert {:ok, %Distilled{} = distilled} =
             Distilled.distill(traces,
               name: :linux_sysadmin_live,
               source: %{kind: :silo, domain: @silo_domain, hologram_id: silo["id"]}
             )

    # 4. Sanity-check the aggregation
    assert distilled.trace_count >= 100
    assert distilled.name == :linux_sysadmin_live
    assert distilled.source.domain == @silo_domain

    # The Linux sysadmin domain should have at least some of these key
    # subjects present after 5 pages on apt/systemctl/iptables/lvm/sysctl.
    expected_subjects = ["apt", "iptables", "lvm"]

    present =
      Enum.filter(expected_subjects, fn s -> Map.has_key?(distilled.rules.by_subject, s) end)

    assert length(present) >= 2,
           "Expected at least 2 of #{inspect(expected_subjects)} as subjects; saw #{inspect(present)}"

    # The top relation should be something semantic (not relates_to — that
    # was the v1 failure mode).
    {top_relation, _count} = hd(distilled.rules.top_relations)

    refute top_relation == "relates_to",
           "Top relation collapsed to 'relates_to' — v1 regression"

    # 5. Permission semantics: known subjects permitted, unknowns denied
    state = %{distilled: distilled}

    known_subject = Enum.at(present, 0) || hd(Map.keys(distilled.rules.by_subject))

    assert :permitted =
             Distilled.permitted?({:install, %{subject: known_subject}}, state),
           "Known subject #{inspect(known_subject)} should be permitted"

    assert {:denied, :no_evidence} =
             Distilled.permitted?(
               {:install, %{subject: "totally_unknown_widget_xyz_#{:rand.uniform(100_000)}"}},
               state
             )
  end
end
