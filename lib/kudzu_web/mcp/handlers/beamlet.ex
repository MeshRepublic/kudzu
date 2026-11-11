defmodule KudzuWeb.MCP.Handlers.Beamlet do
  @moduledoc "MCP handlers for beamlet tools (same lookups as KudzuWeb.BeamletController)."

  alias Kudzu.Beamlet.Supervisor, as: BeamletSup

  @allowed_capabilities ~w(file_read file_write http_get http_post dns_resolve schedule)a

  def handle("kudzu_list_beamlets", _params) do
    # Kudzu.Beamlet.Supervisor is a static Supervisor whose children include
    # the registry and the dynamic supervisor; the registry holds the
    # beamlets themselves (static and dynamically spawned).
    beamlets =
      Registry.select(Kudzu.BeamletRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(fn {key, pid} ->
        %{key: inspect(key), pid: inspect(pid), alive: Process.alive?(pid)}
      end)

    {:ok, %{beamlets: beamlets, count: length(beamlets)}}
  end

  def handle("kudzu_get_beamlet", %{"id" => id}) do
    case BeamletSup.find_by_id(id) do
      {:ok, pid} ->
        {:ok, %{beamlet: GenServer.call(pid, :info)}}

      _ ->
        {:error, -32_602, "Beamlet not found: #{id}"}
    end
  end

  def handle("kudzu_find_beamlets", %{"capability" => capability}) do
    capability_atom = safe_to_capability(capability)

    beamlets =
      BeamletSup.find_by_capability(capability_atom)
      |> Enum.map(fn {pid, id} -> %{id: id, pid: inspect(pid), alive: Process.alive?(pid)} end)

    {:ok, %{capability: capability_atom, beamlets: beamlets, count: length(beamlets)}}
  end

  defp safe_to_capability(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @allowed_capabilities, do: atom, else: :unknown
  rescue
    ArgumentError -> :unknown
  end
end
