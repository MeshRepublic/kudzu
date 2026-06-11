defmodule Kudzu.Constitution.Filter.DistillationRouterTest do
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.Filter.DistillationRouter

  setup do
    salt = :rand.uniform(99_999)
    expertise = "expertise:us_constitution_mesh_test_#{salt}"
    rejection = "rejection:us_constitution_mesh_test_#{salt}"
    contested = "contested:us_constitution_mesh_test_#{salt}"

    {:ok, _} = Kudzu.Silo.create(expertise)
    {:ok, _} = Kudzu.Silo.create(rejection)
    {:ok, _} = Kudzu.Silo.create(contested)

    %{expertise: expertise, rejection: rejection, contested: contested}
  end

  describe "route/4" do
    test ":advances routes to expertise silo", %{expertise: e, rejection: r, contested: c} do
      result =
        DistillationRouter.route(
          {"individual", "has_right_to", "speech"},
          {:advances, 0.9, "free_speech"},
          %{source_doc: "Federalist 84", paragraph_offset: 3},
          %{expertise: e, rejection: r, contested: c}
        )

      assert match?({:ok, _}, result)
      assert_silo_count(e, 1)
      assert_silo_count(r, 0)
      assert_silo_count(c, 0)
    end

    test ":retards routes to rejection silo with reason", %{
      expertise: e,
      rejection: r,
      contested: c
    } do
      DistillationRouter.route(
        {"government", "may_compel", "testimony"},
        {:retards, 0.85, "due_process", "compelled self-incrimination"},
        %{source_doc: "Federalist 84", paragraph_offset: 1},
        %{expertise: e, rejection: r, contested: c}
      )

      assert_silo_count(e, 0)
      assert_silo_count(r, 1)
      assert_silo_count(c, 0)
    end

    test ":contested routes to contested silo", %{expertise: e, rejection: r, contested: c} do
      DistillationRouter.route(
        {"x", "y", "z"},
        {:contested, :three_way_split},
        %{source_doc: "Federalist 10", paragraph_offset: 5},
        %{expertise: e, rejection: r, contested: c}
      )

      assert_silo_count(e, 0)
      assert_silo_count(r, 0)
      assert_silo_count(c, 1)
    end
  end

  defp assert_silo_count(domain, expected) do
    {:ok, pid} = Kudzu.Silo.find(domain)
    traces = :sys.get_state(pid) |> Map.get(:traces) |> Map.values()
    actual = length(traces)

    assert actual == expected,
           "expected #{expected} traces in #{domain}, got #{actual}"
  end
end
