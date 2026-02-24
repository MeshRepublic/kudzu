defmodule KudzuWeb.BrainChatController do
  @moduledoc """
  SSE streaming controller for Brain chat.

  POST /api/v1/brain/chat — SSE stream of Brain reasoning
  GET  /api/v1/brain/status — Brain state as JSON

  Authentication is handled in-controller (not via pipeline plug) because
  we need to return a proper HTTP 401 before switching to chunked/SSE mode.

  Uses Plug.Conn functions for responses (not Phoenix.Controller.json/2)
  so the action functions can also be called from the MCP Plug.Router.
  """

  use Phoenix.Controller, formats: []
  import Plug.Conn
  require Logger

  @doc """
  POST /brain/chat

  Expects JSON body: {"message": "..."}

  On success, switches to SSE (chunked transfer encoding) and streams events:
    event: thinking   data: {"tier": 1, "status": "Checking reflexes..."}
    event: chunk      data: {"text": "..."}
    event: tool_use   data: {"tools": ["tool_name", ...]}
    event: done       data: {"tier": 3, "tool_calls": [...], "cost": 0.001}
    event: error      data: {"error": "timeout"}
  """
  def chat(conn, %{"message" => message}) do
    case authenticate(conn) do
      :ok ->
        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        Kudzu.Brain.chat_stream(message, self())
        stream_loop(conn)

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: reason}))
    end
  end

  def chat(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: "Missing 'message' parameter"}))
  end

  @doc """
  GET /brain/status

  Returns Brain state as JSON:
    {"status": "sleeping", "cycle_count": 42, "hologram_id": "...", ...}
  """
  def status(conn, _params) do
    case authenticate(conn) do
      :ok ->
        state = Kudzu.Brain.get_state()

        result = %{
          status: state.status,
          cycle_count: state.cycle_count,
          hologram_id: state.hologram_id,
          desires: state.desires,
          budget: %{
            estimated_cost_usd: state.budget.estimated_cost_usd,
            api_calls: state.budget.api_calls
          }
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(result))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: reason}))
    end
  end

  # ── SSE Stream Loop ──────────────────────────────────────────────────

  defp stream_loop(conn) do
    receive do
      {:thinking, tier, status} ->
        case sse_event(conn, "thinking", %{tier: tier, status: status}) do
          {:ok, conn} -> stream_loop(conn)
          {:error, _reason} -> conn
        end

      {:chunk, text} ->
        case sse_event(conn, "chunk", %{text: text}) do
          {:ok, conn} -> stream_loop(conn)
          {:error, _reason} -> conn
        end

      {:tool_use, tool_names} ->
        case sse_event(conn, "tool_use", %{tools: tool_names}) do
          {:ok, conn} -> stream_loop(conn)
          {:error, _reason} -> conn
        end

      {:done, metadata} ->
        # Send the final event, then return conn regardless of success/failure
        case sse_event(conn, "done", metadata) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    after
      120_000 ->
        sse_event(conn, "error", %{error: "timeout"})
        conn
    end
  end

  defp sse_event(conn, event, data) do
    payload = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
    chunk(conn, payload)
  end

  # ── Authentication ───────────────────────────────────────────────────

  defp authenticate(conn) do
    auth_config = Application.get_env(:kudzu, :api_auth, [])
    enabled = Keyword.get(auth_config, :enabled, false)

    if not enabled do
      # Auth disabled — allow all requests
      :ok
    else
      api_keys = Keyword.get(auth_config, :api_keys, [])

      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] ->
          if token in api_keys, do: :ok, else: {:error, "Invalid API key"}

        _ ->
          {:error, "Authorization header required"}
      end
    end
  end
end
