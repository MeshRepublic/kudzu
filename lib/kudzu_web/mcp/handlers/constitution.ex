defmodule KudzuWeb.MCP.Handlers.Constitution do
  @moduledoc "MCP handlers for constitution tools."

  alias Kudzu.Constitution

  @frameworks ~w(mesh_republic cautious open kudzu_evolve)a

  def handle("kudzu_list_constitutions", _params) do
    frameworks =
      Enum.map(@frameworks, fn name ->
        %{name: name, principles: Constitution.principles(name)}
      end)

    {:ok, %{constitutions: frameworks}}
  end

  def handle("kudzu_get_constitution_details", %{"name" => name}) do
    atom = safe_atom(name)

    if atom in @frameworks do
      {:ok, %{name: atom, principles: Constitution.principles(atom)}}
    else
      {:error, -32_602, "Unknown constitution: #{name}"}
    end
  end

  def handle("kudzu_check_constitution", %{"name" => name, "action" => action} = params) do
    atom = safe_atom(name)
    context = Map.get(params, "context", %{})

    # This tool is reachable with a read-scoped key, so it must never create
    # atoms from caller input (atoms are never garbage collected). An action
    # name that is not already an atom cannot match any constitution clause.
    with {:framework, true} <- {:framework, atom in @frameworks},
         {:action, action_atom} when not is_nil(action_atom) <- {:action, safe_atom(action)} do
      result = Constitution.permitted?(atom, {action_atom, context}, %{})
      {:ok, %{constitution: atom, action: action, result: format_decision(result)}}
    else
      {:framework, false} -> {:error, -32_602, "Unknown constitution: #{name}"}
      {:action, nil} -> {:error, -32_602, "Unknown action: #{action}"}
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
