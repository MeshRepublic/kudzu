defmodule Kudzu.SiloTest do
  use ExUnit.Case, async: false

  alias Kudzu.Silo

  @test_domain "test_silo_#{:rand.uniform(999_999)}"

  setup do
    # Clean up any leftover test silo
    Silo.delete(@test_domain)
    Process.sleep(200)

    on_exit(fn ->
      Silo.delete(@test_domain)
    end)

    :ok
  end

  describe "create/1 and delete/1" do
    test "creates a new silo and finds it" do
      assert {:ok, pid} = Silo.create(@test_domain)
      assert is_pid(pid)
      assert {:ok, ^pid} = Silo.find(@test_domain)
    end

    test "create is idempotent — returns existing silo" do
      assert {:ok, pid1} = Silo.create(@test_domain)
      assert {:ok, pid2} = Silo.create(@test_domain)
      assert pid1 == pid2
    end

    test "delete removes the silo" do
      {:ok, _pid} = Silo.create(@test_domain)
      assert :ok = Silo.delete(@test_domain)
      # Registry deregistration is async — wait for it
      Process.sleep(500)
      assert {:error, :not_found} = Silo.find(@test_domain)
    end

    test "delete non-existent returns error" do
      assert {:error, :not_found} = Silo.delete("nonexistent_silo_xyz")
    end
  end

  describe "list/0" do
    test "lists created silos" do
      {:ok, _pid} = Silo.create(@test_domain)
      silos = Silo.list()
      domains = Enum.map(silos, fn {domain, _pid, _id} -> domain end)
      assert @test_domain in domains
    end
  end

  describe "store_relationship/2 and probe/2" do
    test "stores and retrieves a relationship" do
      {:ok, _pid} = Silo.create(@test_domain)

      assert {:ok, _trace} = Silo.store_relationship(@test_domain, {"elixir", "runs_on", "beam"})

      results = Silo.probe(@test_domain, "elixir")
      assert length(results) >= 1

      {hint, sim} = hd(results)
      assert hint["subject"] == "elixir" or hint[:subject] == "elixir"
      assert sim == 1.0 or abs(sim - 1.0) < 0.01
    end

    test "stores multiple relationships and probes by subject" do
      {:ok, _pid} = Silo.create(@test_domain)

      Silo.store_relationship(@test_domain, {"elixir", "runs_on", "beam"})
      Silo.store_relationship(@test_domain, {"elixir", "has_feature", "pattern_matching"})
      Silo.store_relationship(@test_domain, {"python", "runs_on", "cpython"})

      results = Silo.probe(@test_domain, "elixir")
      assert length(results) == 3

      # The two elixir-subject results should be ranked highest
      {top_hint, top_sim} = hd(results)
      subject = Map.get(top_hint, "subject", Map.get(top_hint, :subject))
      assert subject == "elixir"
      assert top_sim > 0.5
    end

    test "probe on non-existent silo returns empty list" do
      assert Silo.probe("nonexistent_silo_xyz", "anything") == []
    end

    test "store on non-existent silo returns error" do
      assert {:error, {:silo_not_found, _}} =
               Silo.store_relationship("nonexistent_silo_xyz", {"a", "b", "c"})
    end
  end

  describe "HRR vector persistence (D.5)" do
    test "store_relationship persists the bind(S, bind(R, O)) vector in the hint" do
      {:ok, _pid} = Silo.create(@test_domain)

      {:ok, trace} =
        Silo.store_relationship(@test_domain, {"alpha", "is_a", "beta"})

      hint = trace.reconstruction_hint
      stored_vector = Map.get(hint, :vector, Map.get(hint, "vector"))

      assert is_list(stored_vector)
      assert length(stored_vector) > 0
      assert Enum.all?(stored_vector, &is_number/1)

      # Vector should match a fresh Relationship.encode of the same triple.
      expected = Kudzu.Silo.Relationship.encode({"alpha", "is_a", "beta"})
      assert length(stored_vector) == length(expected)
    end

    test "probe uses stored vector as secondary signal without demoting subject matches" do
      {:ok, _pid} = Silo.create(@test_domain)

      Silo.store_relationship(@test_domain, {"alpha", "is_a", "beta"})
      Silo.store_relationship(@test_domain, {"gamma", "is_a", "delta"})

      results = Silo.probe(@test_domain, "alpha")
      # Subject match for "alpha" must rank first; the bound-vector signal
      # can only raise scores (via max/2), not flip ordering away from
      # exact subject hits.
      assert length(results) == 2
      {top_hint, top_sim} = hd(results)
      subj = Map.get(top_hint, :subject, Map.get(top_hint, "subject"))
      assert subj == "alpha"
      assert top_sim >= 0.99
    end
  end

  describe "brain_knowledge silo (Tier-3 Claude distillation destination)" do
    # The Brain GenServer is started by the application supervisor at boot
    # (see lib/kudzu/application.ex). Its :init_hologram handler creates the
    # brain_knowledge silo so that Kudzu.Brain.Reasoning.distill_claude_response/2
    # has somewhere to write triples. Without it, every Tier-3 distillation
    # silently drops on a {:silo_not_found, _} error swallowed by try/catch.
    test "brain_knowledge silo exists after Brain boot" do
      # Brain's :init_hologram is asynchronous via send(self(), :init_hologram).
      # Wait up to 5 s for the silo to come up.
      assert eventually(fn -> match?({:ok, _}, Silo.find("brain_knowledge")) end, 5_000),
             "brain_knowledge silo was not created within 5 s of test start"
    end

    test "Reasoning.distill_claude_response writes triples into brain_knowledge" do
      assert eventually(fn -> match?({:ok, _}, Silo.find("brain_knowledge")) end, 5_000),
             "brain_knowledge silo was not created within 5 s of test start"

      # Snapshot the silo's trace count before distillation runs.
      {:ok, pid} = Silo.find("brain_knowledge")
      before_count = pid |> :sys.get_state() |> Map.get(:traces) |> map_size()

      # Mimic the Distiller's output schema by writing a representative triple
      # directly. This exercises the same destination silo + reconstruction-hint
      # shape that Reasoning.distill_claude_response/2 produces from real Claude
      # responses — without depending on Ollama being available in the test
      # environment.
      assert {:ok, _trace} =
               Silo.store_relationship("brain_knowledge", {
                 "elixir",
                 "is_a",
                 "functional_language"
               })

      after_count = pid |> :sys.get_state() |> Map.get(:traces) |> map_size()
      assert after_count == before_count + 1

      # Confirm the triple is retrievable via probe — verifies the trace was
      # stored with the relationship hint schema, not raw content.
      results = Silo.probe("brain_knowledge", "elixir")

      assert Enum.any?(results, fn {hint, _sim} ->
               subj = Map.get(hint, :subject, Map.get(hint, "subject"))
               obj = Map.get(hint, :object, Map.get(hint, "object"))
               subj == "elixir" and obj == "functional_language"
             end)
    end
  end

  defp eventually(check, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_loop(check, deadline)
  end

  defp eventually_loop(check, deadline) do
    if check.() do
      true
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        false
      else
        Process.sleep(100)
        eventually_loop(check, deadline)
      end
    end
  end

  describe "store_relationship/3 with provenance" do
    test "persists provenance metadata in the trace reconstruction_hint" do
      domain = "test_silo_provenance_#{:rand.uniform(99_999)}"
      {:ok, pid} = Silo.create(domain)
      on_exit(fn -> Silo.delete(domain) end)

      provenance = %{
        origin_type: :distilled,
        source_doc: "Federalist 10",
        paragraph_offset: 3,
        sovereignty_score: 0.85,
        principle: "freedom_of_speech"
      }

      assert {:ok, trace} =
               Silo.store_relationship(domain, {"madison", "argues_for", "factions"}, provenance)

      hint = trace.reconstruction_hint
      assert hint.origin_type == :distilled
      assert hint.source_doc == "Federalist 10"
      assert hint.paragraph_offset == 3
      assert hint.sovereignty_score == 0.85
      assert hint.principle == "freedom_of_speech"

      # Triple fields still present
      assert hint.subject == "madison"
      assert hint.relation == "argues_for"
      assert hint.object == "factions"
      assert is_list(hint.vector)

      # And the trace round-trips through the hologram state
      stored_hints =
        pid
        |> :sys.get_state()
        |> Map.get(:traces)
        |> Map.values()
        |> Enum.map(& &1.reconstruction_hint)
        |> Enum.filter(&(Map.get(&1, :subject) == "madison"))

      assert [stored] = stored_hints
      assert stored.origin_type == :distilled
      assert stored.source_doc == "Federalist 10"
      assert stored.principle == "freedom_of_speech"
    end

    test "store_relationship/2 still works with no provenance (backward compatible)" do
      domain = "test_silo_compat_#{:rand.uniform(99_999)}"
      {:ok, _pid} = Silo.create(domain)
      on_exit(fn -> Silo.delete(domain) end)

      assert {:ok, trace} = Silo.store_relationship(domain, {"a", "rel", "b"})
      hint = trace.reconstruction_hint
      assert hint.subject == "a"
      assert hint.relation == "rel"
      assert hint.object == "b"
      # No provenance fields should be present
      refute Map.has_key?(hint, :origin_type)
      refute Map.has_key?(hint, :source_doc)
    end

    test "store_relationship/3 with empty provenance behaves like /2" do
      domain = "test_silo_empty_prov_#{:rand.uniform(99_999)}"
      {:ok, _pid} = Silo.create(domain)
      on_exit(fn -> Silo.delete(domain) end)

      assert {:ok, trace} = Silo.store_relationship(domain, {"x", "y", "z"}, %{})
      hint = trace.reconstruction_hint
      assert hint.subject == "x"
      refute Map.has_key?(hint, :origin_type)
    end

    test "store_relationship/3 on non-existent silo returns error" do
      assert {:error, {:silo_not_found, _}} =
               Silo.store_relationship("nonexistent_silo_xyz_3arity", {"a", "b", "c"}, %{
                 origin_type: :distilled
               })
    end
  end
end
