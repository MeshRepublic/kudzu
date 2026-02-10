defmodule KudzuWeb.BeamletController do
  use Phoenix.Controller

  alias Kudzu.Beamlet.Supervisor

  @doc """
  List all beamlets.
  GET /api/v1/beamlets
  """
  def index(conn, _params) do
    beamlets = Registry.select(Kudzu.BeamletRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {key, pid} ->
      %{
        key: inspect(key),
        pid: inspect(pid),
        alive: Process.alive?(pid)
      }
    end)

    json(conn, %{beamlets: beamlets, count: length(beamlets)})
  end

  @doc """
  Get beamlet info.
  GET /api/v1/beamlets/:id
  """
  def show(conn, %{"id" => id}) do
    case find_beamlet(id) do
      {:ok, pid} ->
        info = GenServer.call(pid, :info)
        json(conn, %{beamlet: info})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Beamlet not found"})
    end
  end

  @doc """
  Find beamlets by capability.
  GET /api/v1/beamlets/capabilities/:capability
  """
  def by_capability(conn, %{"capability" => capability}) do
    capability_atom = safe_to_capability(capability)

    beamlets = Supervisor.find_by_capability(capability_atom)
    |> Enum.map(fn {pid, id} ->
      %{
        id: id,
        pid: inspect(pid),
        alive: Process.alive?(pid)
      }
    end)

    json(conn, %{
      capability: capability_atom,
      beamlets: beamlets,
      count: length(beamlets)
    })
  end

  defp find_beamlet(id) do
    # Look up by ID in registry
    case Registry.lookup(Kudzu.BeamletRegistry, {:id, id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @allowed_capabilities ~w(file_read file_write http_get http_post dns_resolve schedule)a

  defp safe_to_capability(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @allowed_capabilities, do: atom, else: :unknown
  rescue
    ArgumentError -> :unknown
  end
end
