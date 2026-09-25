defmodule Kudzu.HologramDeleteTest do
  @moduledoc """
  Regression: deleting a hologram used GenServer.stop/2. Holograms are
  :permanent children of Kudzu.HologramSupervisor, so each "deleted"
  hologram was restarted (under a fresh id when it had none), and a few
  deletes within 5 s exceeded the supervisor's restart intensity -- taking
  down every hologram on the node.
  """
  use ExUnit.Case, async: false

  alias KudzuWeb.MCP.Handlers.Hologram, as: Handler

  test "deleting holograms neither resurrects them nor takes the supervisor down" do
    supervisor = Process.whereis(Kudzu.HologramSupervisor)
    purpose = "delete_test_#{System.unique_integer([:positive])}"

    pids =
      for _ <- 1..10 do
        {:ok, pid} = Kudzu.Application.spawn_hologram(purpose: purpose, cognition: false)
        pid
      end

    for pid <- pids do
      id = Kudzu.Hologram.get_id(pid)
      assert {:ok, %{deleted: true}} = Handler.handle("kudzu_delete_hologram", %{"id" => id})
    end

    Process.sleep(200)
    assert Process.whereis(Kudzu.HologramSupervisor) == supervisor
    assert Registry.lookup(Kudzu.Registry, {:purpose, purpose}) == []
  end
end
