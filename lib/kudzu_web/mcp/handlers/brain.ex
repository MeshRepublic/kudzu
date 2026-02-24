defmodule KudzuWeb.MCP.Handlers.Brain do
  @moduledoc "MCP handler for Brain chat and status tools."

  def handle("kudzu_brain_chat", %{"message" => message} = args) do
    api_key = Map.get(args, "api_key", "")

    configured_keys =
      Application.get_env(:kudzu, :api_auth, [])
      |> Keyword.get(:api_keys, [])

    if api_key in configured_keys do
      case Kudzu.Brain.chat(message) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    else
      {:error, -32602, "Invalid or missing api_key"}
    end
  end

  def handle("kudzu_brain_status", _args) do
    state = Kudzu.Brain.get_state()
    {:ok, %{
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

  def handle(tool, _args), do: {:error, -32602, "Unknown brain tool: #{tool}"}
end
