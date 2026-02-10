defmodule KudzuWeb.Plugs.APIAuth do
  @moduledoc """
  API authentication plug.

  Supports multiple auth methods:
  - Bearer token (API key)
  - No auth (if configured to allow)

  Configure in config.exs:
      config :kudzu, :api_auth,
        enabled: true,
        api_keys: ["key1", "key2"]
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    if auth_enabled?() do
      case get_auth_token(conn) do
        {:ok, token} ->
          if valid_token?(token) do
            conn
            |> assign(:authenticated, true)
            |> assign(:api_key, token)
          else
            conn
            |> put_status(:unauthorized)
            |> Phoenix.Controller.json(%{error: "Invalid API key"})
            |> halt()
          end

        :error ->
          conn
          |> put_status(:unauthorized)
          |> Phoenix.Controller.json(%{error: "Authorization header required"})
          |> halt()
      end
    else
      # Auth disabled - allow all requests
      assign(conn, :authenticated, false)
    end
  end

  defp auth_enabled? do
    Application.get_env(:kudzu, :api_auth, [])
    |> Keyword.get(:enabled, false)
  end

  defp get_auth_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> :error
    end
  end

  defp valid_token?(token) do
    api_keys = Application.get_env(:kudzu, :api_auth, [])
    |> Keyword.get(:api_keys, [])

    token in api_keys
  end
end
