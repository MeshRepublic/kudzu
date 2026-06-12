defmodule Kudzu.Brain.SelfConverse do
  @moduledoc """
  AGI self-conversation loop skeleton.

  Defines the interface between recursive-cognition consumers (the AGI
  brake in `Kudzu.Constitution.Distilled.loop_permitted?/3`) and the
  loop driver. The actual loop implementation is deferred to a future
  sub-project; this module only nails down the contract so the brake
  has a stable interface to call into.

  Bodies all raise `:not_implemented`. The interface IS the spec.
  """

  @max_depth Application.compile_env(:kudzu, :self_converse_max_depth, 10)

  # Stubs intentionally raise — they are interface placeholders, not
  # implementations. Real bodies land in the deferred self-converse sub-project.
  @dialyzer {:nowarn_function, loop_step: 3, converged?: 1}

  @doc """
  Maximum recursion depth for self-conversation. Hard structural ceiling;
  exceeding this is a halt regardless of constitutional judgment. Default
  10; configurable via `:kudzu, :self_converse_max_depth`.
  """
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Advance the loop by one iteration.

  Inputs:
    * `state` — the hologram's working state (carrying loop bookkeeping,
      cost meter, prior outputs)
    * `prior_output` — the previous turn's output (string)
    * `depth` — current recursion depth

  Returns `{:ok, new_state, next_output}` or `{:halt, reason, state}`.

  NOT IMPLEMENTED. Calls into `Constitution.Distilled.loop_permitted?/3`
  to obtain the constitutional brake decision; if permitted, calls the
  LLM with the assembled prompt; otherwise halts with the brake's
  reason.
  """
  @spec loop_step(map(), String.t(), non_neg_integer()) ::
          {:ok, map(), String.t()} | {:halt, term(), map()}
  def loop_step(_state, _prior_output, _depth) do
    raise "Brain.SelfConverse.loop_step/3 not implemented — interface skeleton only. See Constitution distillation sub-project §Brain.SelfConverse for the deferred implementation."
  end

  @doc """
  Has the self-conversation converged?

  Inputs:
    * `state` — the hologram's working state

  Returns `true` when the loop should naturally terminate (semantic
  entropy below a threshold, goal achieved, etc.). NOT IMPLEMENTED.
  """
  @spec converged?(map()) :: boolean()
  def converged?(_state) do
    raise "Brain.SelfConverse.converged?/1 not implemented — interface skeleton only."
  end
end
