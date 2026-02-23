defmodule KudzuWeb.MCP.Endpoint do
  @moduledoc """
  Phoenix endpoint for MCP Streamable HTTP.
  Binds to Tailscale IP only.
  """
  use Phoenix.Endpoint, otp_app: :kudzu

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :mcp_endpoint]

  plug KudzuWeb.MCP.Router
end
