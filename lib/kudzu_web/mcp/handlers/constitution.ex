defmodule KudzuWeb.MCP.Handlers.Constitution do
  @moduledoc "MCP handlers for constitution tools."

  alias Kudzu.Constitution

  @frameworks ~w(mesh_republic cautious open kudzu_evolve)a

  def handle("kudzu_list_constitutions", _params) do
    frameworks = Enum.map(@frameworks, fn name ->
      %{name: name, principles: Constitution.principles(name)}
    end)
    {:ok, %{constitutions: frameworks}}
  end

  def handle("kudzu_get_constitution_details", %{"name" => name}) do
    atom = safe_atom(name)
    if atom in @frameworks do
      {:ok, %{name: atom, principles: Constitution.principles(atom)}}
    else
      {:error, -32602, "Unknown constitution: #{name}"}
    end
  end

  def handle("kudzu_check_constitution", %{"name" => name, "action" => action} = params) do
    atom = safe_atom(name)
    context = Map.get(params, "context", %{})
    if atom in @frameworks do
      action_tuple = {String.to_atom(action), context}
      result = Constitution.permitted?(atom, action_tuple, %{})
      {:ok, %{constitution: atom, action: action, result: format_decision(result)}}
    else
      {:error, -32602, "Unknown constitution: #{name}"}
    end
  end

  defp safe_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp format_decision(:permitted), do: "permitted"
  defp format_decision({:denied, reason}), do: "denied: #{reason}"
  defp format_decision({:requires_consensus, threshold}), do: "requires_consensus: #{threshold}"
end
