defmodule Kudzu.Beamlet.Behaviour do
  @moduledoc """
  Behaviour defining the beam-let interface.

  Beam-lets are execution substrate agents that provide capabilities
  to purpose holograms. They handle:
  - IO operations (file, network, external APIs)
  - Scheduling hints and prioritization
  - Resource management and allocation
  - Hardware abstraction

  Purpose holograms discover and delegate to beam-lets through
  proximity-based routing, not direct calls.
  """

  @type capability :: atom()
  @type request_id :: String.t()
  @type beamlet_id :: String.t()

  @doc """
  Return the capabilities this beam-let provides.
  """
  @callback capabilities() :: [capability()]

  @doc """
  Handle a request from a hologram.
  Returns {:ok, result} or {:error, reason}.
  """
  @callback handle_request(request :: map(), from :: beamlet_id()) ::
              {:ok, term()} | {:error, term()} | {:async, request_id()}

  @doc """
  Get current load/capacity for load balancing decisions.
  Returns a float 0.0 (idle) to 1.0 (fully loaded).
  """
  @callback current_load() :: float()

  @doc """
  Health check - is this beam-let operational?
  """
  @callback healthy?() :: boolean()
end
