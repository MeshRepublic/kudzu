defmodule Kudzu.Constitution do
  @moduledoc """
  Constitutional Framework Manager.

  Manages pluggable constitutional frameworks that bound agent behavior.
  Constitutions can be:
  - Injected at hologram spawn time
  - Hot-swapped at runtime
  - Queried for permission before actions
  - Used to constrain desires and audit decisions

  Available frameworks:
  - `:mesh_republic` - Distributed, transparent, anti-centralization
  - `:cautious` - Highly restrictive, explicit permission required
  - `:open` - No constraints (testing only)

  ## Example

      # Check if action is permitted
      Kudzu.Constitution.permitted?(:mesh_republic, {:share_trace, %{peer: "abc"}}, state)

      # Constrain desires before cognition
      desires = Kudzu.Constitution.constrain(:mesh_republic, raw_desires, state)

      # Audit a decision
      Kudzu.Constitution.audit(:mesh_republic, trace, :permitted, state)
  """

  alias Kudzu.Constitution.{MeshRepublic, Cautious, Open, KudzuEvolve}

  @type framework :: :mesh_republic | :cautious | :open | :kudzu_evolve | module()
  @type action :: {atom(), map()} | atom()
  @type decision :: :permitted | {:denied, atom()} | {:requires_consensus, float()}

  @frameworks %{
    mesh_republic: MeshRepublic,
    cautious: Cautious,
    open: Open,
    kudzu_evolve: KudzuEvolve
  }

  @doc """
  Get the module for a constitutional framework.
  """
  @spec get_framework(framework()) :: module() | nil
  def get_framework(name) when is_atom(name) do
    Map.get(@frameworks, name) || if is_atom(name) and function_exported?(name, :permitted?, 2), do: name
  end

  @doc """
  Check if an action is permitted under a constitution.
  """
  @spec permitted?(framework(), action(), map()) :: decision()
  def permitted?(framework, action, state) do
    case get_framework(framework) do
      nil -> {:denied, :unknown_constitution}
      mod -> mod.permitted?(action, state)
    end
  end

  @doc """
  Constrain desires according to constitutional principles.
  """
  @spec constrain(framework(), [String.t()], map()) :: [String.t()]
  def constrain(framework, desires, state) do
    case get_framework(framework) do
      nil -> desires
      mod -> mod.constrain(desires, state)
    end
  end

  @doc """
  Audit a constitutional decision.
  """
  @spec audit(framework(), map(), decision(), map()) :: {:ok, String.t()} | {:error, term()}
  def audit(framework, trace, decision, state) do
    case get_framework(framework) do
      nil -> {:error, :unknown_constitution}
      mod -> mod.audit(trace, decision, state)
    end
  end

  @doc """
  Check if action requires consensus.
  """
  @spec consensus_required?(framework(), action(), map()) :: {:required, float()} | :not_required
  def consensus_required?(framework, action, state) do
    case get_framework(framework) do
      nil -> :not_required
      mod ->
        if function_exported?(mod, :consensus_required?, 2) do
          mod.consensus_required?(action, state)
        else
          :not_required
        end
    end
  end

  @doc """
  Validate a trace against constitutional requirements.
  """
  @spec validate_trace(framework(), map(), map()) :: :valid | {:invalid, atom()}
  def validate_trace(framework, trace, state) do
    case get_framework(framework) do
      nil -> :valid
      mod ->
        if function_exported?(mod, :validate_trace, 2) do
          mod.validate_trace(trace, state)
        else
          :valid
        end
    end
  end

  @doc """
  Get the name of a constitutional framework.
  """
  @spec name(framework()) :: atom()
  def name(framework) do
    case get_framework(framework) do
      nil -> :unknown
      mod -> mod.name()
    end
  end

  @doc """
  Get the principles of a constitutional framework.
  """
  @spec principles(framework()) :: [String.t()]
  def principles(framework) do
    case get_framework(framework) do
      nil -> []
      mod ->
        if function_exported?(mod, :principles, 0) do
          mod.principles()
        else
          []
        end
    end
  end

  @doc """
  List available constitutional frameworks.
  """
  @spec available_frameworks() :: [atom()]
  def available_frameworks do
    Map.keys(@frameworks)
  end

  @doc """
  Compare how different constitutions would handle an action.
  """
  @spec compare_decisions(action(), map()) :: %{atom() => decision()}
  def compare_decisions(action, state) do
    @frameworks
    |> Enum.map(fn {name, _mod} ->
      {name, permitted?(name, action, state)}
    end)
    |> Map.new()
  end
end
