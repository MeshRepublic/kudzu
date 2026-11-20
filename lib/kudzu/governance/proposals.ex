defmodule Kudzu.Governance.Proposals do
  @moduledoc """
  In-memory store of evaluated governance proposals with single-use vote
  tokens.

  A proposal is evaluated once from free text by
  `Kudzu.Constitution.Distilled.explain/2`; the decision and stages are stored
  exactly as returned and are never altered here. Each evaluated proposal
  carries one governance token, separate from money and with no monetary value
  (Mesh Republic white paper §4.4.3). The token is spent by the proposal's one
  vote. Only proposals decided `:permitted_with_weight` are votable.

  The GenServer owns a private ETS table and performs every mutation, so
  concurrent votes serialise and at most one can succeed. The table holds at
  most #{500} proposals; the oldest are evicted first.
  """

  use GenServer

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Constitution.Filter.SovereigntyFilter
  alias Kudzu.Constitution.Vectors
  alias Kudzu.Constitution.WeightLedger

  @max_proposals 500

  @typedoc "A stored proposal as returned to callers (the vector stays internal)."
  @type proposal :: %{
          id: String.t(),
          text: String.t(),
          principle: String.t(),
          decision: Kudzu.Constitution.Behaviour.decision(),
          stages: [Distilled.stage()],
          silos_empty: boolean(),
          token: %{id: String.t(), spent: boolean()},
          vote: nil | :yes | :no,
          evaluated_at: DateTime.t()
        }

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Evaluates `text` against `principle` and stores the result.

  `opts[:config]` is passed as the evaluation `state.config`.
  """
  @spec evaluate(String.t(), String.t(), keyword()) ::
          {:ok, proposal()} | {:error, :empty_text | :unknown_principle}
  def evaluate(text, principle, opts \\ []) do
    with :ok <- check_principle(principle),
         {:ok, vector} <- encode(text) do
      action = {:propose, %{vector: vector, principle: principle, proposal_text: text}}
      state = %{config: Keyword.get(opts, :config, %{})}
      %{decision: decision, stages: stages} = Distilled.explain(action, state)

      stored = %{
        id: random_id(),
        text: text,
        principle: principle,
        decision: decision,
        stages: stages,
        silos_empty: Kudzu.Silo.list_traces(Distilled.default_expertise_silo()) == [],
        token: %{id: random_id(), spent: false},
        vote: nil,
        evaluated_at: DateTime.utc_now()
      }

      GenServer.call(__MODULE__, {:insert, stored, vector})
    end
  end

  @doc "Casts the proposal's single vote, spending its token."
  @spec vote(String.t(), :yes | :no) ::
          {:ok, proposal()} | {:error, :not_found | :not_votable | :already_voted}
  def vote(id, choice) when choice in [:yes, :no] do
    GenServer.call(__MODULE__, {:vote, id, choice})
  end

  @spec get(String.t()) :: {:ok, proposal()} | {:error, :not_found}
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc false
  @spec clear_for_test() :: :ok
  def clear_for_test, do: GenServer.call(__MODULE__, :clear_for_test)

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(:kudzu_proposals, [:set, :private])
    {:ok, %{table: table, seq: 0}}
  end

  @impl true
  def handle_call({:insert, proposal, vector}, _from, state) do
    seq = state.seq + 1
    :ets.insert(state.table, {proposal.id, seq, proposal, vector})
    evict(state.table)
    {:reply, {:ok, proposal}, %{state | seq: seq}}
  end

  def handle_call({:get, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, _seq, proposal, _vector}] -> {:reply, {:ok, proposal}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:vote, id, choice}, _from, state) do
    reply =
      case :ets.lookup(state.table, id) do
        [] ->
          {:error, :not_found}

        [{^id, seq, proposal, vector}] ->
          cast_vote(state.table, id, seq, proposal, vector, choice)
      end

    {:reply, reply, state}
  end

  def handle_call(:clear_for_test, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  ## Helpers

  defp cast_vote(_table, _id, _seq, %{token: %{spent: true}}, _vector, _choice),
    do: {:error, :already_voted}

  defp cast_vote(
         table,
         id,
         seq,
         %{decision: {:permitted_with_weight, weight, _dv, _dp, _meta}} = proposal,
         vector,
         choice
       ) do
    outcome = if choice == :yes, do: :yes_with_weight, else: :no
    :ok = WeightLedger.record(id, vector, weight, proposal.principle, outcome)
    voted = %{proposal | vote: choice, token: %{proposal.token | spent: true}}
    :ets.insert(table, {id, seq, voted, vector})
    {:ok, voted}
  end

  defp cast_vote(_table, _id, _seq, _proposal, _vector, _choice), do: {:error, :not_votable}

  defp evict(table) do
    excess = :ets.info(table, :size) - @max_proposals

    if excess > 0 do
      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_id, seq, _p, _v} -> seq end)
      |> Enum.take(excess)
      |> Enum.each(fn {id, _seq, _p, _v} -> :ets.delete(table, id) end)
    end
  end

  defp check_principle(principle) do
    if principle in SovereigntyFilter.principles(), do: :ok, else: {:error, :unknown_principle}
  end

  defp encode(text) when is_binary(text) do
    if String.trim(text) == "" do
      {:error, :empty_text}
    else
      case Vectors.encode_text(text) do
        nil -> {:error, :empty_text}
        vector -> {:ok, vector}
      end
    end
  end

  defp random_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
