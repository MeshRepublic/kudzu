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
  - distill/1 - Crystallize a constitution from accumulated traces

  Frameworks can be hot-swapped at runtime, changing permissible actions
  without modifying the underlying cognition architecture.

  ## Bootstrap vs. emergent frameworks

  The included constitutions (`MeshRepublic`, `Cautious`, `Open`,
  `KudzuEvolve`) are bootstrap defaults: hand-coded so the system has
  *something* to enforce before the distillation pipeline is in place.
  The intended path for creating new constitutions is `distill/1`:
  accumulate enough traces in a domain (e.g. Linux sysadmin) and
  crystallize them into a behavioral framework. The 4 defaults all stub
  `distill/1` as `{:error, :not_implemented}` to make the gap visible
  in the contract.
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

  @doc """
  Distill a constitution from accumulated traces.

  This is the intended path for creating constitutions: gather enough
  traces in a domain (e.g. Linux sysadmin), aggregate, and crystallize
  a behavioral framework. The 4 hand-coded implementations are bootstrap
  defaults; their `distill/1` returns `{:error, :not_implemented}` to
  make the gap visible.

  When a real distillation pipeline lands (likely consuming
  `Kudzu.Brain.Distiller` + `Kudzu.Silo` output — see the
  `expertise:linux_sysadmin_test_v2` silo for the kind of input this
  will see, 733 triples at 97.8% useful), this is the contract it
  satisfies.

  ## Return values

  - `{:ok, module}` - a module that itself implements
    `Kudzu.Constitution.Behaviour`, ready to be registered and used.
  - `{:error, :not_implemented}` - the implementation is a bootstrap
    default with no distillation logic yet.
  - `{:error, term}` - distillation attempted but failed (insufficient
    traces, contradictory signals, etc.).
  """
  @callback distill(traces :: [Kudzu.Trace.t()]) :: {:ok, module()} | {:error, term()}

  @optional_callbacks [consensus_required?: 2, validate_trace: 2, principles: 0]
end
