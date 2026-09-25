defmodule KudzuWeb.AuthScopeTest do
  @moduledoc """
  Scoped API keys across every entry point: /mcp, REST /api/v1, and the
  WebSocket share one key store (KudzuWeb.Plugs.APIAuth).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]
  import Phoenix.ChannelTest

  alias KudzuWeb.MCP.{Controller, Tools}
  alias KudzuWeb.Plugs.APIAuth

  @endpoint KudzuWeb.MCP.Endpoint

  @mutate_key "test-mutate-key"
  @read_key "test-read-key"

  setup do
    original = Application.get_env(:kudzu, :api_auth)

    Application.put_env(:kudzu, :api_auth, keys: %{@mutate_key => :mutate, @read_key => :read})

    on_exit(fn -> Application.put_env(:kudzu, :api_auth, original) end)
    :ok
  end

  defp mcp(method, body, key) do
    conn = conn(method, "/mcp", body)
    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    KudzuWeb.MCP.Router.call(conn, KudzuWeb.MCP.Router.init([]))
  end

  defp call_tool(name, key, args \\ %{}) do
    conn =
      mcp(
        :post,
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => args}
        },
        key
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp rest(method, path, key, body \\ nil) do
    conn = if body, do: conn(method, path, body), else: conn(method, path)
    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    KudzuWeb.Router.call(conn, KudzuWeb.Router.init([]))
  end

  # Side-effect checks look for a uniquely named hologram rather than
  # comparing global counts, which other async test modules change.
  defp unique_purpose, do: "auth_scope_#{System.unique_integer([:positive])}"

  defp hologram_with_purpose?(purpose) do
    Enum.any?(Kudzu.Application.list_holograms(), fn pid ->
      try do
        to_string(Kudzu.Hologram.get_state(pid).purpose) == purpose
      catch
        :exit, _ -> false
      end
    end)
  end

  defp mutating_tools do
    Controller.tool_names() |> Enum.filter(&(Controller.required_scope(&1) == :mutate))
  end

  describe "APIAuth key store" do
    test "resolves each key to its scope and rejects unknown keys" do
      assert APIAuth.scope_for_token(@mutate_key) == {:ok, :mutate}
      assert APIAuth.scope_for_token(@read_key) == {:ok, :read}
      assert APIAuth.scope_for_token("nope") == :error
      assert APIAuth.scope_for_token("") == :error
      assert APIAuth.scope_for_token(nil) == :error
    end

    test "mutate grants read; read does not grant mutate" do
      assert APIAuth.permits?(:mutate, :read)
      assert APIAuth.permits?(:mutate, :mutate)
      assert APIAuth.permits?(:read, :read)
      refute APIAuth.permits?(:read, :mutate)
      refute APIAuth.permits?(nil, :read)
    end

    test "no configured keys means nothing authenticates" do
      Application.put_env(:kudzu, :api_auth, keys: nil)
      assert APIAuth.scope_for_token(@mutate_key) == :error
    end
  end

  describe "/mcp authentication" do
    test "unauthenticated POST /mcp is 401" do
      conn = mcp(:post, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, nil)
      assert conn.status == 401
    end

    test "invalid key on POST /mcp is 401" do
      conn = mcp(:post, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, "bogus")
      assert conn.status == 401
    end

    test "unauthenticated GET and DELETE /mcp are 401" do
      assert mcp(:get, nil, nil).status == 401
      assert mcp(:delete, nil, nil).status == 401
    end

    test "unauthenticated tool call does not execute the tool" do
      purpose = unique_purpose()
      {status, _} = call_tool("kudzu_create_hologram", nil, %{"purpose" => purpose})
      assert status == 401
      refute hologram_with_purpose?(purpose)
    end

    test "read key can call a read tool" do
      {200, body} = call_tool("kudzu_health", @read_key)
      refute body["result"]["isError"]
      assert [%{"type" => "text"}] = body["result"]["content"]
    end
  end

  describe "/mcp read scope" do
    test "every non-read tool is refused for a read key" do
      tools = mutating_tools()
      assert "kudzu_create_hologram" in tools
      assert "kudzu_delete_hologram" in tools
      assert "kudzu_set_hologram_constitution" in tools

      for tool <- tools do
        {200, body} = call_tool(tool, @read_key)

        assert body["error"]["code"] == -32_003,
               "#{tool} was not refused for a read key: #{inspect(body)}"
      end
    end

    test "a refused mutating call has no side effect" do
      purpose = unique_purpose()
      {200, body} = call_tool("kudzu_create_hologram", @read_key, %{"purpose" => purpose})
      assert body["error"]["code"] == -32_003
      refute hologram_with_purpose?(purpose)
    end

    test "batched requests are scope-checked per item" do
      body = [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "kudzu_health"}
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "kudzu_delete_hologram", "arguments" => %{"id" => "x"}}
        }
      ]

      responses = Controller.dispatch({:batch, Enum.map(body, &parse/1)}, :read)
      {:batch_response, [ok, forbidden]} = responses
      assert ok["result"]
      assert forbidden["error"]["code"] == -32_003
    end

    test "tools/list only advertises tools the key may call" do
      {:response, read_list} = Controller.dispatch({:request, 1, "tools/list", %{}}, :read)
      read_names = Enum.map(read_list["result"]["tools"], & &1["name"])

      assert "kudzu_health" in read_names
      refute Enum.any?(read_names, &(&1 in mutating_tools()))

      {:response, full} = Controller.dispatch({:request, 1, "tools/list", %{}}, :mutate)
      assert length(full["result"]["tools"]) == length(Tools.list())
    end

    test "mutate key can call mutating tools" do
      {200, body} = call_tool("kudzu_create_hologram", @mutate_key, %{"purpose" => "scope_test"})
      refute body["error"]
      refute body["result"]["isError"]
      %{"id" => id} = Jason.decode!(hd(body["result"]["content"])["text"])
      call_tool("kudzu_delete_hologram", @mutate_key, %{"id" => id})
    end

    test "every advertised tool has a handler (unlisted tools default to mutate)" do
      names = Enum.map(Tools.list(), & &1.name)
      assert Enum.sort(names) == Enum.sort(Controller.tool_names())
      assert Controller.required_scope("some_future_tool") == :mutate
    end
  end

  describe "REST /api/v1 scope" do
    test "no key is 401" do
      assert rest(:get, "/api/v1/holograms", nil).status == 401
    end

    test "read key can GET" do
      assert rest(:get, "/api/v1/holograms", @read_key).status == 200
    end

    test "read key cannot POST/PUT/DELETE" do
      assert rest(:post, "/api/v1/holograms", @read_key, %{"purpose" => "x"}).status == 403
      assert rest(:delete, "/api/v1/holograms/abc", @read_key).status == 403
      assert rest(:put, "/api/v1/holograms/abc/constitution", @read_key, %{}).status == 403
    end

    test "read key can use the POST check endpoint" do
      conn =
        rest(:post, "/api/v1/constitutions/mesh_republic/check", @read_key, %{
          "action_type" => "record_trace"
        })

      assert conn.status == 200
    end

    test "brain chat requires a mutate key" do
      conn = rest(:post, "/api/v1/brain/chat", @read_key, %{"message" => "hi"})
      assert conn.status == 403
    end
  end

  describe "WebSocket scope" do
    test "connect without a valid token is refused" do
      assert :error = connect(KudzuWeb.HologramSocket, %{})
      assert :error = connect(KudzuWeb.HologramSocket, %{"token" => "bogus"})
    end

    test "connect assigns the key's scope" do
      {:ok, socket} = connect(KudzuWeb.HologramSocket, %{"token" => @read_key})
      assert socket.assigns.api_scope == :read
    end

    test "read key cannot spawn a hologram via hologram:new" do
      {:ok, socket} = connect(KudzuWeb.HologramSocket, %{"token" => @read_key})
      assert {:error, %{reason: reason}} = subscribe_and_join(socket, "hologram:new", %{})
      assert reason =~ "mutate"
    end

    test "read key can join an existing hologram but not mutate it" do
      {:ok, pid} = Kudzu.Application.spawn_hologram(purpose: :ws_scope_test, cognition: false)
      id = Kudzu.Hologram.get_id(pid)

      {:ok, socket} = connect(KudzuWeb.HologramSocket, %{"token" => @read_key})
      {:ok, _reply, socket} = subscribe_and_join(socket, "hologram:" <> id, %{})

      ref = push(socket, "get_state", %{})
      assert_reply(ref, :ok, %{id: ^id})

      ref = push(socket, "add_desire", %{"desire" => "take over"})
      assert_reply(ref, :error, %{reason: reason})
      assert reason =~ "mutate"
      refute "take over" in Kudzu.Hologram.get_desires(pid)

      Kudzu.Application.stop_hologram(pid)
    end
  end

  defp parse(%{"id" => id, "method" => method} = msg),
    do: {:request, id, method, msg["params"] || %{}}
end
