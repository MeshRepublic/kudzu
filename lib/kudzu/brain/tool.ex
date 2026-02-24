defmodule Kudzu.Brain.Tool do
  @moduledoc """
  Behaviour for brain tools callable by Claude during reasoning.

  Each tool module implements four callbacks:

    * `name/0`        — unique string identifier (e.g. "check_health")
    * `description/0` — human-readable description for Claude
    * `parameters/0`  — JSON Schema map describing expected input
    * `execute/1`     — runs the tool and returns `{:ok, result}` or `{:error, reason}`

  Use `to_claude_format/1` to convert any implementing module into the
  map format expected by the Claude Messages API `tools` array.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Convert a tool module to the Claude API tool format.

  Returns a map with `:name`, `:description`, and `:input_schema` keys
  suitable for inclusion in a Claude Messages API request.
  """
  @spec to_claude_format(module()) :: map()
  def to_claude_format(module) do
    %{
      name: module.name(),
      description: module.description(),
      input_schema: module.parameters()
    }
  end
end
