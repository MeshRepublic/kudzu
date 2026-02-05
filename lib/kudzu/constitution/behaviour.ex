defmodule Kudzu.Constitution.Behaviour do
  @moduledoc """
  Behaviour defining the constitutional framework interface.

  Constitutional frameworks bound agent behavior through modular constraint
  systems. Rather than external guardrails, alignment is woven into the
  architecture itself.

  Any constitutional framework must implement:
  - permitted?/2 - Is this action allowed given current state?
  - constrain/2 - Transform desires to comply with constraints
  - audit/2 - Record constitutional decisions for transparency
  - consensus_required?/2 - Does this action need distributed agreement?
  - validate_trace/2 - Verify a trace complies with constitution

  Frameworks can be hot-swapped at runtime, changing permissible actions
  without modifying the underlying cognition architecture.
  """

  @type action :: {atom(), map()}
  @type decision :: :permitted | :denied | {:requires_consensus, threshold :: float()}
  @type audit_result :: {:ok, audit_id :: String.t()} | {:error, term()}
  @type state :: map()

  @doc """
  Check if an action is permitted under this constitution.

  Returns:
  - :permitted - Action may proceed
  - :denied - Action is forbidden, with reason
  - {:requires_consensus, threshold} - Needs distributed agreement
  """
  @callback permitted?(action :: action(), state :: state()) ::
              :permitted | {:denied, reason :: atom()} | {:requires_consensus, float()}

  @doc """
  Transform or constrain desires to comply with this constitution.

  Takes a list of desires and returns modified desires that comply
  with constitutional constraints. May add, remove, or modify desires.
  """
  @callback constrain(desires :: [String.t()], state :: state()) :: [String.t()]

  @doc """
  Record a constitutional decision for transparency and accountability.

  All permitted actions should be audited. The audit trail enables:
  - Verification of constitutional compliance
  - Distributed oversight
  - Learning from past decisions
  """
  @callback audit(trace :: map(), decision :: decision(), state :: state()) :: audit_result()

  @doc """
  Check if an action requires distributed consensus.

  Some actions may need agreement from multiple agents before proceeding.
  Returns the consensus threshold (0.0-1.0) or :no_consensus_needed.
  """
  @callback consensus_required?(action :: action(), state :: state()) ::
              {:required, threshold :: float()} | :not_required

  @doc """
  Validate that a trace complies with constitutional requirements.

  Used to verify historical actions and detect constitutional violations.
  """
  @callback validate_trace(trace :: map(), state :: state()) ::
              :valid | {:invalid, reason :: atom()}

  @doc """
  Get the name/identifier of this constitutional framework.
  """
  @callback name() :: atom()

  @doc """
  Get human-readable description of the constitutional principles.
  """
  @callback principles() :: [String.t()]

  @optional_callbacks [consensus_required?: 2, validate_trace: 2, principles: 0]
end
