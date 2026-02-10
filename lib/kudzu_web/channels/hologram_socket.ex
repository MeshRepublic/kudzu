defmodule KudzuWeb.HologramSocket do
  use Phoenix.Socket

  channel "hologram:*", KudzuWeb.HologramChannel

  @impl true
  def connect(params, socket, _connect_info) do
    # Optional: verify API key from params
    case verify_token(params) do
      {:ok, _} ->
        {:ok, socket}

      :error ->
        # Allow connection but mark as unauthenticated
        {:ok, assign(socket, :authenticated, false)}
    end
  end

  @impl true
  def id(_socket), do: nil

  defp verify_token(%{"token" => token}) do
    api_keys = Application.get_env(:kudzu, :api_auth, [])
    |> Keyword.get(:api_keys, [])

    if token in api_keys, do: {:ok, token}, else: :error
  end
  defp verify_token(_), do: :error
end
