defmodule KudzuWeb.MCP.Handlers.Beamlet do
  @moduledoc "MCP handlers for beamlet tools."

  alias Kudzu.Beamlet.Supervisor, as: BeamletSup

  def handle("kudzu_list_beamlets", _params) do
    beamlets = DynamicSupervisor.which_children(BeamletSup)
    |> Enum.map(fn {_, pid, _, _} ->
      try do
        %{pid: inspect(pid), alive: Process.alive?(pid)}
      rescue
        _ -> %{pid: inspect(pid), alive: false}
      end
    end)
    {:ok, %{beamlets: beamlets, count: length(beamlets)}}
  end

  def handle("kudzu_get_beamlet", %{"id" => _id}) do
    {:error, -32602, "Beamlet lookup by ID not supported — use kudzu_list_beamlets"}
  end

  def handle("kudzu_find_beamlets", %{"capability" => capability}) do
    known = ~w(file_read file_write http_get http_post dns_resolve schedule)
    if capability in known do
      {:ok, %{capability: capability, available: true}}
    else
      {:ok, %{capability: capability, available: false}}
    end
  end
end
