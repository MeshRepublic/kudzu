defmodule KudzuWeb.MCP.Router do
  @moduledoc """
  Plug router for MCP Streamable HTTP.
  Handles POST, GET, DELETE on /mcp, plus brain chat endpoints.

  Unmatched requests fall through to KudzuWeb.Router (Phoenix)
  so the full REST API is available on the same port.
  """
  use Plug.Router

  alias KudzuWeb.MCP.{Protocol, Controller, Session}

  plug :match
  plug :dispatch

  # POST /mcp — Client-to-server JSON-RPC messages
  post "/mcp" do
    session_id = get_req_header(conn, "mcp-session-id") |> List.first()

    case Protocol.parse_request(conn.body_params) do
      {:error, :invalid_request} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(Protocol.encode_error(nil, -32700, "Parse error")))

      parsed ->
        result = Controller.dispatch(parsed)

        # Touch session if present
        if session_id, do: Session.touch(session_id)

        case result do
          {:response, %{"result" => %{"protocolVersion" => _}} = response} ->
            # Initialize response — create session and return ID
            {:ok, new_session_id} = Session.create()
            conn
            |> put_resp_header("mcp-session-id", new_session_id)
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response))

          {:response, response} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response))

          {:batch_response, responses} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(responses))

          :accepted ->
            send_resp(conn, 202, "")
        end
    end
  end

  # GET /mcp — SSE stream for server-initiated messages
  get "/mcp" do
    # We don't currently need server-initiated messages.
    # Return 405 as per spec when not supported.
    send_resp(conn, 405, "")
  end

  # DELETE /mcp — Session termination
  delete "/mcp" do
    case get_req_header(conn, "mcp-session-id") |> List.first() do
      nil -> send_resp(conn, 400, "")
      session_id ->
        Session.destroy(session_id)
        send_resp(conn, 200, "")
    end
  end

  # Brain chat SSE endpoint (also kept here for backward compat with /brain/chat)
  post "/brain/chat" do
    KudzuWeb.BrainChatController.chat(conn, conn.body_params)
  end

  get "/brain/status" do
    KudzuWeb.BrainChatController.status(conn, conn.params)
  end

  # Unmatched requests fall through to the Phoenix router
  match _ do
    KudzuWeb.Router.call(conn, KudzuWeb.Router.init([]))
  end
end
