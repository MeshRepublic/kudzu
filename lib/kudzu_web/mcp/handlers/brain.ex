defmodule KudzuWeb.MCP.Handlers.Brain do
  @moduledoc "MCP handler for Brain chat and status tools."

  # Authentication and scope (mutate) are enforced at the HTTP layer by
  # KudzuWeb.MCP.Router / Controller; any legacy "api_key" argument is ignored.
  def handle("kudzu_brain_chat", %{"message" => message}) do
    case Kudzu.Brain.chat(message) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, -32_603, inspect(reason)}
    end
  end

  def handle("kudzu_brain_status", _args) do
    state = Kudzu.Brain.get_state()

    {:ok,
     %{
       status: state.status,
       cycle_count: state.cycle_count,
       hologram_id: state.hologram_id,
       desires: state.desires,
       budget: %{
         estimated_cost_usd: state.budget.estimated_cost_usd,
         api_calls: state.budget.api_calls,
         month: state.budget.month
       }
     }}
  end

  def handle(tool, _args), do: {:error, -32_602, "Unknown brain tool: #{tool}"}
end
