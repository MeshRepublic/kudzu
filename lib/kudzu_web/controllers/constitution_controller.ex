defmodule KudzuWeb.ConstitutionController do
  use Phoenix.Controller

  alias Kudzu.Constitution

  @frameworks [:mesh_republic, :cautious, :open, :kudzu_evolve]

  @doc """
  List available constitutional frameworks.
  GET /api/v1/constitutions
  """
  def index(conn, _params) do
    frameworks = Enum.map(@frameworks, fn name ->
      %{
        name: name,
        principles: Constitution.principles(name)
      }
    end)

    json(conn, %{constitutions: frameworks})
  end

  @doc """
  Get details of a specific constitutional framework.
  GET /api/v1/constitutions/:name
  """
  def show(conn, %{"name" => name}) do
    case safe_to_constitution(name) do
      {:ok, constitution} ->
        json(conn, %{
          constitution: %{
            name: constitution,
            principles: Constitution.principles(constitution)
          }
        })

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Constitution not found", available: @frameworks})
    end
  end

  @doc """
  Check if an action is permitted under a constitution.
  POST /api/v1/constitutions/:name/check
  """
  def check_permission(conn, %{"name" => name} = params) do
    action_type = Map.get(params, "action_type", "unknown")
    action_params = Map.get(params, "action_params", %{})
    state = Map.get(params, "state", %{})

    case safe_to_constitution(name) do
      {:ok, constitution} ->
        action = {safe_to_action_atom(action_type), action_params}
        result = Constitution.permitted?(constitution, action, state)

        json(conn, %{
          constitution: constitution,
          action: action_type,
          result: format_permission_result(result)
        })

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Constitution not found"})
    end
  end

  defp safe_to_constitution(name) when is_binary(name) do
    atom = String.to_existing_atom(name)
    if atom in @frameworks, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  @allowed_actions ~w(
    record_trace recall think observe share_trace query_peer
    file_read file_write http_get http_post spawn respond
  )a

  defp safe_to_action_atom(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @allowed_actions, do: atom, else: :unknown
  rescue
    ArgumentError -> :unknown
  end

  defp format_permission_result(:permitted), do: %{permitted: true}
  defp format_permission_result({:denied, reason}), do: %{permitted: false, reason: inspect(reason)}
  defp format_permission_result({:requires_consensus, threshold}), do: %{permitted: false, requires_consensus: threshold}
  defp format_permission_result(other), do: %{permitted: false, raw: inspect(other)}
end
