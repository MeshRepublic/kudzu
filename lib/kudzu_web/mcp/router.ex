defmodule KudzuWeb.MCP.Router do
  @moduledoc """
  Plug router for MCP Streamable HTTP.
  Handles POST, GET, DELETE on /mcp, plus brain chat endpoints.

  Unmatched requests fall through to KudzuWeb.Router (Phoenix)
  so the full REST API is available on the same port.

  Every /mcp request must carry a valid bearer key (401 otherwise). The
  key's scope is passed to `Controller.dispatch/2`, which enforces
  per-tool scope.
  """
  use Plug.Router

  alias KudzuWeb.MCP.{Controller, Protocol, Session}
  alias KudzuWeb.Plugs.APIAuth

  plug(:match)
  plug(:dispatch)

  # POST /mcp — Client-to-server JSON-RPC messages
  post "/mcp" do
    with_auth(conn, fn conn, scope -> handle_post(conn, scope) end)
  end

  # GET /mcp — SSE stream for server-initiated messages
  get "/mcp" do
    # We don't currently need server-initiated messages.
    # Return 405 as per spec when not supported.
    with_auth(conn, fn conn, _scope -> send_resp(conn, 405, "") end)
  end

  # DELETE /mcp — Session termination
  delete "/mcp" do
    with_auth(conn, fn conn, _scope ->
      case get_req_header(conn, "mcp-session-id") |> List.first() do
        nil ->
          send_resp(conn, 400, "")

        session_id ->
          Session.destroy(session_id)
          send_resp(conn, 200, "")
      end
    end)
  end

  # Brain chat SSE endpoint (also kept here for backward compat with /brain/chat)
  # — the controller enforces auth itself (mutate for chat, read for status).
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

  # Any valid key (read or mutate) may reach /mcp; per-tool scope is
  # enforced in Controller.dispatch/2.
  defp with_auth(conn, fun) do
    case APIAuth.authorize(conn, :read) do
      {:ok, scope} ->
        fun.(conn, scope)

      {:error, status, message} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{error: message}))
    end
  end

  defp handle_post(conn, scope) do
    session_id = get_req_header(conn, "mcp-session-id") |> List.first()

    case Protocol.parse_request(conn.body_params) do
      {:error, :invalid_request} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(Protocol.encode_error(nil, -32_700, "Parse error")))

      parsed ->
        result = Controller.dispatch(parsed, scope)

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
end
