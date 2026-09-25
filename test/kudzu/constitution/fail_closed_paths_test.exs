defmodule Kudzu.Constitution.FailClosedPathsTest do
  @moduledoc """
  Every enforcement point fails closed: consensus, errors, unknown decision
  shapes, missing frameworks and the opt-in :open framework never turn into
  permission.
  """
  # async: false — toggles :allow_open_constitution and spawns holograms.
  use ExUnit.Case, async: false

  alias Kudzu.{Constitution, Hologram}
  alias Kudzu.Constitution.{Distilled, Open}
  alias Kudzu.Hologram.Runner

  # A framework double whose decision is chosen per test.
  defmodule Scripted do
    @behaviour Kudzu.Constitution.Behaviour
    def name, do: :scripted
    def principles, do: []
    def permitted?(_action, _state), do: decide()
    def constrain(desires, _state), do: desires
    def audit(_trace, _decision, _state), do: {:ok, "audit"}
    def distill(_), do: {:error, :not_implemented}
    def loop_permitted?(_, _, _), do: {:error, :not_implemented}

    def decide do
      case :persistent_term.get({__MODULE__, :decision}) do
        {:raise, message} -> raise message
        decision -> decision
      end
    end

    def set(decision), do: :persistent_term.put({__MODULE__, :decision}, decision)
  end

  defp hologram_with(decision) do
    Scripted.set(decision)
    {:ok, pid} = Kudzu.Application.spawn_hologram(purpose: :fail_closed_paths, cognition: false)
    :ok = Hologram.set_constitution(pid, Scripted)
    on_exit(fn -> Kudzu.Application.stop_hologram(pid) end)
    pid
  end

  # Drive the hologram's enforcement point the way cognition does.
  defp run_actions(pid, actions) do
    send(pid, {:cognition_result, actions, [], "test stimulus"})
    Hologram.get_state(pid)
  end

  describe "Constitution.classify/1" do
    test "maps every decision shape; unknown shapes deny" do
      assert Constitution.classify(:permitted) == :permit
      assert Constitution.classify({:permitted_with_weight, 0.4, [], "p", %{}}) == :permit
      assert Constitution.classify({:requires_consensus, 0.8}) == {:consensus, 0.8}
      assert Constitution.classify({:denied, :x}) == {:deny, :x}
      assert Constitution.classify({:denied, "cite", "p", "why"}) == {:deny, {"cite", "p", "why"}}

      assert {:deny, {:accumulation, "p", [1]}} =
               Constitution.classify({:denied_by_accumulation, [1], "p"})

      assert {:deny, {:unrecognized_decision, {:deny, "legacy"}}} =
               Constitution.classify({:deny, "legacy"})

      assert {:deny, {:unrecognized_decision, :maybe}} = Constitution.classify(:maybe)
    end
  end

  describe "hologram enforcement point" do
    test "a 4-tuple denial is recorded, not executed, and does not crash the hologram" do
      pid = hologram_with({:denied, "Sedition Act", "free_speech", "criminalizes speech"})

      state =
        run_actions(pid, [{:record_trace, :observation, %{content: "should not be recorded"}}])

      assert Process.alive?(pid)
      purposes = state.traces |> Map.values() |> Enum.map(& &1.purpose)
      assert :action_denied in purposes
      refute :observation in purposes
    end

    test "an unrecognised decision denies instead of crashing" do
      pid = hologram_with({:weird, :shape})
      state = run_actions(pid, [{:update_desire, "take over"}])
      assert Process.alive?(pid)
      refute "take over" in state.desires
    end

    test "requires_consensus does not execute the action" do
      pid = hologram_with({:requires_consensus, 0.8})
      state = run_actions(pid, [{:update_desire, "needs a vote"}])
      refute "needs a vote" in state.desires
    end
  end

  describe "Runner gate" do
    setup do
      pid = hologram_with(:permitted)
      %{runner_state: %Runner{hologram_pid: pid}}
    end

    test "consensus is not permission", %{runner_state: s} do
      Scripted.set({:requires_consensus, 0.5})
      assert {:denied, {:consensus_required, 0.5}} = Runner.check_constitution(s, :web_research)
    end

    test "a check that raises is not permission", %{runner_state: s} do
      Scripted.set({:raise, "boom"})
      assert {:denied, {:check_failed, _, _}} = Runner.check_constitution(s, :web_research)
    end

    test "weighted permits and plain permits pass", %{runner_state: s} do
      Scripted.set({:permitted_with_weight, 0.3, [], "p", %{}})
      assert :permitted = Runner.check_constitution(s, :reasoning)
    end
  end

  describe "Distilled legacy path" do
    test "no distilled framework loaded denies" do
      assert {:denied, :no_distilled_framework} =
               Distilled.permitted?({:install, %{subject: "apt"}}, %{})
    end

    test "an action with no subject denies" do
      d = %Distilled{
        name: "t",
        rules: %{by_subject: %{"apt" => []}},
        source: %{},
        trace_count: 0,
        distilled_at: 0
      }

      assert {:denied, :no_subject} = Distilled.permitted?({:install, %{}}, %{distilled: d})
    end
  end

  describe ":open constitution is opt-in" do
    setup do
      previous = Application.get_env(:kudzu, :allow_open_constitution)
      Application.put_env(:kudzu, :allow_open_constitution, false)
      on_exit(fn -> Application.put_env(:kudzu, :allow_open_constitution, previous) end)
    end

    test "disabled: denies every action" do
      refute Open.allowed?()

      assert {:denied, :open_constitution_disabled} =
               Constitution.permitted?(:open, {:anything, %{}}, %{})
    end

    test "disabled: holograms refuse to switch to it" do
      {:ok, pid} = Kudzu.Application.spawn_hologram(purpose: :open_refusal, cognition: false)
      on_exit(fn -> Kudzu.Application.stop_hologram(pid) end)
      assert {:error, :open_constitution_disabled} = Hologram.set_constitution(pid, :open)
      refute Hologram.get_constitution(pid) == :open
    end
  end
end
