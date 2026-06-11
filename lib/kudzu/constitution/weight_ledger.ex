defmodule Kudzu.Constitution.WeightLedger do
  @moduledoc """
  Persistent ledger of citizen-ratified ambiguous proposals.

  Architecture:
    * ETS table for fast principle-scoped lookups
    * DETS table for durability across restart
    * Anchor-ready schema: each entry has an `anchor_status` field
      (`:pending | :anchored`) that sub-project 3 (Bitcoin anchoring)
      will drain.

  The ledger is the constitutional-debt clock: each citizen-ratified
  weighted proposal accumulates weight on the principle under pressure.
  `accumulated_weight/2` returns the HRR-superposed vector + scalar sum
  for evaluating Stage 2 of the runtime pipeline.

  Vote semantics (spec decision #6):
    * `:yes_with_weight` — entry RECORDED (democratic ratification adds
      weight)
    * `:no` — entry NOT recorded (citizens rejected the pressure)
  """

  use GenServer

  require Logger

  @ets_table :kudzu_weight_ledger
  @dets_subdir "dets"
  @dets_filename "weight_ledger.dets"

  defmodule Entry do
    @moduledoc false
    defstruct [
      :proposal_id,
      :vector,
      :weight,
      :principle,
      :vote_outcome,
      :recorded_at,
      :anchor_status
    ]

    @type t :: %__MODULE__{
            proposal_id: String.t(),
            vector: Kudzu.HRR.vector(),
            weight: float(),
            principle: String.t(),
            vote_outcome: :yes_with_weight | :no,
            recorded_at: DateTime.t(),
            anchor_status: :pending | :anchored
          }
  end

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(String.t(), Kudzu.HRR.vector(), float(), String.t(), :yes_with_weight | :no) :: :ok
  def record(proposal_id, vector, weight, principle, vote_outcome) do
    GenServer.call(__MODULE__, {:record, proposal_id, vector, weight, principle, vote_outcome})
  end

  @spec accumulated_weight(Kudzu.HRR.vector(), String.t()) :: {Kudzu.HRR.vector(), float()}
  def accumulated_weight(_proposal_vector, principle) do
    entries = entries_for_principle(principle)

    case entries do
      [] ->
        {Kudzu.HRR.zero_vector(Kudzu.HRR.default_dim()), 0.0}

      list ->
        vectors = Enum.map(list, & &1.vector)
        scalar = Enum.reduce(list, 0.0, fn e, acc -> acc + e.weight end)
        acc_v = Kudzu.HRR.bundle(vectors)
        {acc_v, scalar}
    end
  end

  @spec entries_for_principle(String.t()) :: [Entry.t()]
  def entries_for_principle(principle) do
    @ets_table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, %Entry{principle: p}} -> p == principle end)
    |> Enum.map(fn {_id, entry} -> entry end)
  end

  @spec anchor_pending() :: [Entry.t()]
  def anchor_pending do
    @ets_table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, %Entry{anchor_status: s}} -> s == :pending end)
    |> Enum.map(fn {_id, entry} -> entry end)
  end

  @doc false
  def clear_for_test do
    GenServer.call(__MODULE__, :clear_for_test)
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    data_root = Application.fetch_env!(:kudzu, :data_root)
    dets_dir = Path.join(data_root, @dets_subdir)
    File.mkdir_p!(dets_dir)
    dets_path = dets_dir |> Path.join(@dets_filename) |> String.to_charlist()

    :ets.new(@ets_table, [:set, :protected, :named_table, read_concurrency: true])

    {:ok, dets} = :dets.open_file(dets_path, type: :set)

    # Load DETS into ETS on init
    :dets.traverse(dets, fn {k, v} ->
      :ets.insert(@ets_table, {k, v})
      :continue
    end)

    {:ok, %{dets: dets}}
  end

  @impl true
  def handle_call({:record, proposal_id, _vector, _weight, principle, :no}, _from, state) do
    # :no votes do not record — citizens rejected the pressure.
    Phoenix.PubSub.broadcast(
      Kudzu.PubSub,
      "traces:weight_ledger",
      {:weight_recorded, proposal_id, principle}
    )

    {:reply, :ok, state}
  end

  def handle_call(
        {:record, proposal_id, vector, weight, principle, vote_outcome},
        _from,
        state
      ) do
    entry = %Entry{
      proposal_id: proposal_id,
      vector: vector,
      weight: weight,
      principle: principle,
      vote_outcome: vote_outcome,
      recorded_at: DateTime.utc_now(),
      anchor_status: :pending
    }

    :ets.insert(@ets_table, {proposal_id, entry})
    :ok = :dets.insert(state.dets, {proposal_id, entry})
    :ok = :dets.sync(state.dets)

    :telemetry.execute(
      [:kudzu, :constitution, :weight_ledger, :recorded],
      %{weight: weight},
      %{proposal_id: proposal_id, principle: principle}
    )

    Phoenix.PubSub.broadcast(
      Kudzu.PubSub,
      "traces:weight_ledger",
      {:weight_recorded, proposal_id, principle}
    )

    {:reply, :ok, state}
  end

  def handle_call(:clear_for_test, _from, state) do
    :ets.delete_all_objects(@ets_table)
    :ok = :dets.delete_all_objects(state.dets)
    :ok = :dets.sync(state.dets)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.dets)
    :ok
  end
end
