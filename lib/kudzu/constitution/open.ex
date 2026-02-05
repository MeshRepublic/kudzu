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
  def permitted?(_action, _state), do: :permitted

  @impl true
  def constrain(desires, _state), do: desires

  @impl true
  def audit(_trace, _decision, _state), do: {:ok, "not-audited"}

  @impl true
  def consensus_required?(_action, _state), do: :not_required

  @impl true
  def validate_trace(_trace, _state), do: :valid
end
