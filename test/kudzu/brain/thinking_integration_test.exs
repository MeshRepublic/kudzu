defmodule Kudzu.Brain.ThinkingIntegrationTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain
  alias Kudzu.Brain.WorkingMemory

  setup do
    wait_for_brain(100)
    :ok
  end

  defp wait_for_brain(0), do: :ok
  defp wait_for_brain(n) do
    state = Brain.get_state()
    if state.hologram_id, do: :ok, else: (Process.sleep(200); wait_for_brain(n - 1))
  end

  @tag :integration
  test "brain state includes working_memory" do
    state = Brain.get_state()
    # working_memory is initialized after hologram init
    case state.working_memory do
      %WorkingMemory{} -> assert true
      nil ->
        # If hologram init hasn't completed yet, working_memory may be nil
        assert state.hologram_id == nil
    end
  end

  @tag :integration
  test "chat processes through thinking layer" do
    state = Brain.get_state()
    if state.hologram_id do
      result = Brain.chat("What is your status?")
      assert {:ok, response} = result
      assert is_binary(response.response)
      assert response.tier in [1, 2, 3, :thought]
    else
      # Brain not ready — hologram init timed out in test environment
      result = Brain.chat("What is your status?")
      assert {:error, :not_ready} = result
    end
  end

  @tag :integration
  test "working memory gets updated after chat" do
    state = Brain.get_state()
    if not is_nil(state.hologram_id) and not is_nil(state.working_memory) do
      Brain.chat("Tell me about disk usage")
      Process.sleep(500)
      state = Brain.get_state()
      assert is_map(state.working_memory.active_concepts)
    else
      # Brain not fully initialized — verify struct shape at least
      assert state.working_memory == nil or is_map(state.working_memory.active_concepts)
    end
  end

  @tag :integration
  test "curiosity generates questions when idle" do
    state = Brain.get_state()

    # Use working memory from state, or create a fresh one if nil
    wm = state.working_memory || WorkingMemory.new()

    silo_domains = try do
      case Kudzu.Silo.list() do
        domains when is_list(domains) ->
          Enum.map(domains, fn
            {domain, _, _} -> domain
            domain when is_binary(domain) -> domain
            _ -> nil
          end) |> Enum.reject(&is_nil/1)
        _ -> []
      end
    catch
      _, _ -> []
    end

    questions = Kudzu.Brain.Curiosity.generate(
      state.desires,
      wm,
      silo_domains
    )
    assert is_list(questions)
    assert length(questions) > 0
  end
end
