defmodule Kudzu.StorageEmbedBatchTest do
  @moduledoc """
  embed_batch/1 calls the embedder (Ollama, up to 30 s per trace) in the
  caller, so a slow embedding never blocks store/3 in the Storage server.
  """
  use ExUnit.Case, async: false

  alias Kudzu.Storage

  defmodule SlowEmbedder do
    def embed(_text, _opts) do
      Process.sleep(1_500)
      {:ok, List.duplicate(0.1, 8)}
    end
  end

  setup do
    previous = Application.get_env(:kudzu, :embedder)
    Application.put_env(:kudzu, :embedder, SlowEmbedder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kudzu, :embedder, previous),
        else: Application.delete_env(:kudzu, :embedder)
    end)
  end

  defp trace(n) do
    %Kudzu.Trace{
      id: "embed_batch_#{n}_#{System.unique_integer([:positive])}",
      origin: "embed_test",
      timestamp: Kudzu.VectorClock.new("embed_test"),
      purpose: :observation,
      path: ["embed_test"],
      reconstruction_hint: %{content: "a trace long enough to be embedded #{n}"}
    }
  end

  test "a slow embedding batch does not block stores" do
    for n <- 1..3, do: :ok = Storage.store(trace(n), "embed_test")

    batch = Task.async(fn -> Storage.embed_batch(3) end)
    # Let the batch reach the slow embedder.
    Process.sleep(200)

    {elapsed_us, :ok} = :timer.tc(fn -> Storage.store(trace(99), "embed_test") end)

    assert elapsed_us < 500_000,
           "store blocked for #{div(elapsed_us, 1000)} ms behind embed_batch"

    assert is_integer(Task.await(batch, 30_000))
  end
end
