defmodule KudzuWeb.FallbackController do
  use Phoenix.Controller

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found", path: conn.request_path})
  end
end
