defmodule Kudzu.HologramRegistryReconstructTest do
  @moduledoc """
  Boot-time reconstruction must not block the registry (new holograms call
  register/2 from init/1) and must be idempotent.
  """
  use ExUnit.Case, async: false

  alias Kudzu.{Hologram, HologramRegistry}

  defp live_pids(id), do: Registry.lookup(Kudzu.Registry, {:id, id})

  # A hologram can exit between the Registry lookup and the stop.
  defp cleanup(id) do
    HologramRegistry.deregister(id)

    Enum.each(live_pids(id), fn {pid, _} ->
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp record(id) do
    {:ok, record} = HologramRegistry.get(id)
    record
  end

  defp persisted_record(purpose) do
    id = "recon" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      HologramRegistry.register(id, %{
        purpose: purpose,
        constitution: :kudzu_evolve,
        desires: ["remember"],
        cognition_enabled: false,
        cognition_model: "mistral:latest"
      })

    id
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && eventually(fun, attempts - 1)
    end
  end

  test "startup reconstruction is reported finished" do
    assert eventually(&HologramRegistry.reconstructed?/0)
  end

  test "respawns a persisted hologram with its config, exactly once across repeated calls" do
    id = persisted_record(:reconstruct_test)
    assert live_pids(id) == []

    HologramRegistry.reconstruct([record(id)])
    assert [{pid, :reconstruct_test}] = live_pids(id)
    assert Hologram.get_state(pid).constitution == :kudzu_evolve

    HologramRegistry.reconstruct([record(id)])
    assert [{^pid, _}] = live_pids(id)

    cleanup(id)
  end

  test "the registry keeps answering register/2 while reconstruction runs" do
    ids = for i <- 1..40, do: persisted_record(:"reconstruct_load_#{rem(i, 4)}")

    records = Enum.map(ids, &record/1)
    task = Task.async(fn -> HologramRegistry.reconstruct(records) end)

    # A brand-new hologram registers itself synchronously in init/1; before
    # the fix this call queued behind the whole reconstruction.
    {elapsed_us, {:ok, pid}} =
      :timer.tc(fn -> Kudzu.Application.spawn_hologram(purpose: :during_reconstruction) end)

    assert elapsed_us < 2_000_000
    Task.await(task, 60_000)

    new_id = Hologram.get_id(pid)
    assert {:ok, %{purpose: :during_reconstruction}} = HologramRegistry.get(new_id)

    Enum.each([new_id | ids], &cleanup/1)
  end
end
