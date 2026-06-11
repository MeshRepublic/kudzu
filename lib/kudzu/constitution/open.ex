defmodule Kudzu.Constitution.Open do
  @moduledoc """
  Open Constitutional Framework - minimal constraints for testing.

  This framework permits all actions and performs no auditing.
  Useful for:
  - Development and testing
  - Benchmarking without constitutional overhead
  - Exploring unconstrained agent behavior

  WARNING: Not suitable for production or multi-tenant environments.
  """

  @behaviour Kudzu.Constitution.Behaviour

  @impl true
  def name, do: :open

  @impl true
  def principles do
    [
      "All actions are permitted",
      "No auditing or oversight",
      "Agents have full autonomy",
      "For testing and development only"
    ]
  end

  @impl true
  def permitted?(_action, _state) do
    if Application.get_env(:kudzu, :env) == :prod do
      {:deny, "Open constitution is not available in production"}
    else
      :permitted
    end
  end

  @impl true
  def constrain(desires, _state), do: desires

  @impl true
  def audit(_trace, _decision, _state), do: {:ok, "not-audited"}

  @impl true
  def consensus_required?(_action, _state), do: :not_required

  @impl true
  def validate_trace(_trace, _state), do: :valid

  @impl true
  @doc """
  Bootstrap default — distillation is not implemented for `Open`.

  `Open` is a hand-coded permissive framework, not the product of
  distillation from accumulated traces. See `Kudzu.Constitution`'s
  module documentation for the intended emergent-framework workflow.
  """
  @spec distill([Kudzu.Trace.t()]) :: {:error, :not_implemented}
  def distill(_traces), do: {:error, :not_implemented}

  @impl true
  @doc """
  Bootstrap stub. The hand-coded `Open` constitution does not yet
  implement loop governance for AGI self-conversation. Distilled
  constitutions implement this via the 5-stage `permitted?/2` pipeline.
  """
  @spec loop_permitted?(map(), Kudzu.HRR.vector(), non_neg_integer()) ::
          {:error, :not_implemented}
  def loop_permitted?(_state, _thought_vector, _depth), do: {:error, :not_implemented}
end
