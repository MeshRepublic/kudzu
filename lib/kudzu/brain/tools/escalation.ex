defmodule Kudzu.Brain.Tools.Escalation do
  @moduledoc "Alert recording tool for the brain."

  alias Kudzu.Brain.Tool

  defmodule RecordAlert do
    @moduledoc "Record a high-priority alert trace for human review."
    @behaviour Tool

    @impl true
    def name, do: "record_alert"

    @impl true
    def description,
      do:
        "Record a high-priority alert trace for human review. " <>
          "Use when you detect something that needs sysadmin attention."

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          severity: %{type: "string", description: "warning or critical"},
          summary: %{type: "string", description: "Brief description of the issue"},
          context: %{type: "string", description: "What you observed and what you tried"},
          suggested_action: %{type: "string", description: "What the sysadmin should do"}
        },
        required: ["severity", "summary"]
      }
    end

    @impl true
    def execute(params) do
      brain_state = Kudzu.Brain.get_state()

      if brain_state.hologram_pid do
        Kudzu.Hologram.record_trace(brain_state.hologram_pid, :observation, %{
          alert: true,
          severity: params["severity"] || "warning",
          summary: params["summary"],
          context: params["context"],
          suggested_action: params["suggested_action"],
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:ok, %{recorded: true, severity: params["severity"]}}
      else
        {:error, "Brain hologram not ready"}
      end
    end
  end

  @doc "Returns the list of all escalation tool modules."
  @spec all_tools() :: [module()]
  def all_tools, do: [RecordAlert]

  @doc "Converts all escalation tools to Claude API format."
  @spec to_claude_format() :: [map()]
  def to_claude_format do
    Enum.map(all_tools(), &Tool.to_claude_format/1)
  end

  @doc """
  Dispatch a tool call by name string.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec execute(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(name, params) do
    case Enum.find(all_tools(), fn mod -> mod.name() == name end) do
      nil -> {:error, "unknown escalation tool: #{name}"}
      mod -> mod.execute(params)
    end
  end
end
