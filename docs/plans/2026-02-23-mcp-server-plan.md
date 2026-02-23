# Kudzu MCP Server Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an MCP Streamable HTTP server to Kudzu, bound to the Tailscale IP, exposing the full Kudzu API as 45 MCP tools.

**Architecture:** A separate Phoenix endpoint (`KudzuWeb.MCP.Endpoint`) on port 4001 bound to the Tailscale IP handles MCP Streamable HTTP. A single `/mcp` route accepts POST (JSON-RPC 2.0 requests), GET (SSE), and DELETE (session termination). Tool calls dispatch through a registry to handler modules that call Kudzu internals directly.

**Tech Stack:** Elixir, Phoenix 1.7, Cowboy, ETS (sessions), JSON-RPC 2.0

**Source location:** `/home/eel/claude/kudzu_src/` (local copy, rsynced to titan for deployment)

---

### Task 1: MCP Protocol Module

**Files:**
- Create: `lib/kudzu_web/mcp/protocol.ex`
- Test: `test/kudzu_web/mcp/protocol_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu_web/mcp/protocol_test.exs
defmodule KudzuWeb.MCP.ProtocolTest do
  use ExUnit.Case, async: true
  alias KudzuWeb.MCP.Protocol

  describe "encode_response/2" do
    test "encodes a successful result" do
      result = Protocol.encode_response("req-1", %{tools: []})
      assert result == %{"jsonrpc" => "2.0", "id" => "req-1", "result" => %{tools: []}}
    end
  end

  describe "encode_error/3" do
    test "encodes a JSON-RPC error" do
      result = Protocol.encode_error("req-1", -32601, "Method not found")
      assert result == %{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "error" => %{"code" => -32601, "message" => "Method not found"}
      }
    end
  end

  describe "parse_request/1" do
    test "parses a valid JSON-RPC request" do
      body = %{"jsonrpc" => "2.0", "id" => "r1", "method" => "tools/list", "params" => %{}}
      assert {:request, "r1", "tools/list", %{}} = Protocol.parse_request(body)
    end

    test "parses a notification (no id)" do
      body = %{"jsonrpc" => "2.0", "method" => "initialized"}
      assert {:notification, "initialized", %{}} = Protocol.parse_request(body)
    end

    test "returns error for invalid request" do
      assert {:error, :invalid_request} = Protocol.parse_request(%{"foo" => "bar"})
    end

    test "parses a batch of requests" do
      batch = [
        %{"jsonrpc" => "2.0", "id" => "1", "method" => "ping"},
        %{"jsonrpc" => "2.0", "method" => "initialized"}
      ]
      assert {:batch, parsed} = Protocol.parse_request(batch)
      assert length(parsed) == 2
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/protocol_test.exs`
Expected: FAIL — module not found

**Step 3: Write minimal implementation**

```elixir
# lib/kudzu_web/mcp/protocol.ex
defmodule KudzuWeb.MCP.Protocol do
  @moduledoc "JSON-RPC 2.0 encoding/decoding for MCP Streamable HTTP."

  def encode_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  def encode_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  def parse_request(body) when is_list(body) do
    {:batch, Enum.map(body, &parse_request/1)}
  end

  def parse_request(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = body) do
    {:request, id, method, Map.get(body, "params", %{})}
  end

  def parse_request(%{"jsonrpc" => "2.0", "method" => method} = body) do
    {:notification, method, Map.get(body, "params", %{})}
  end

  def parse_request(_), do: {:error, :invalid_request}
end
```

**Step 4: Run test to verify it passes**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/protocol_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
cd /home/eel/claude/kudzu_src && git add lib/kudzu_web/mcp/protocol.ex test/kudzu_web/mcp/protocol_test.exs
git commit -m "feat(mcp): add JSON-RPC 2.0 protocol module"
```

---

### Task 2: MCP Session Manager

**Files:**
- Create: `lib/kudzu_web/mcp/session.ex`
- Test: `test/kudzu_web/mcp/session_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu_web/mcp/session_test.exs
defmodule KudzuWeb.MCP.SessionTest do
  use ExUnit.Case, async: false
  alias KudzuWeb.MCP.Session

  setup do
    # Session GenServer should be started by application, but for isolated tests start it manually
    start_supervised!(Session)
    :ok
  end

  test "create returns a session ID" do
    {:ok, session_id} = Session.create()
    assert is_binary(session_id)
    assert String.length(session_id) > 0
  end

  test "validate returns true for valid session" do
    {:ok, session_id} = Session.create()
    assert Session.valid?(session_id) == true
  end

  test "validate returns false for unknown session" do
    assert Session.valid?("nonexistent") == false
  end

  test "touch updates last_active" do
    {:ok, session_id} = Session.create()
    :ok = Session.touch(session_id)
    assert Session.valid?(session_id) == true
  end

  test "destroy removes session" do
    {:ok, session_id} = Session.create()
    :ok = Session.destroy(session_id)
    assert Session.valid?(session_id) == false
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/session_test.exs`
Expected: FAIL — module not found

**Step 3: Write minimal implementation**

```elixir
# lib/kudzu_web/mcp/session.ex
defmodule KudzuWeb.MCP.Session do
  @moduledoc "MCP session management backed by ETS."
  use GenServer

  @table :mcp_sessions
  @ttl_ms 30 * 60 * 1000
  @sweep_interval 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def create do
    session_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    :ets.insert(@table, {session_id, System.monotonic_time(:millisecond)})
    {:ok, session_id}
  end

  def valid?(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, _last_active}] -> true
      [] -> false
    end
  end

  def touch(session_id) do
    :ets.update_element(@table, session_id, {2, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def destroy(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @ttl_ms
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
```

**Step 4: Run test to verify it passes**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/session_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
cd /home/eel/claude/kudzu_src && git add lib/kudzu_web/mcp/session.ex test/kudzu_web/mcp/session_test.exs
git commit -m "feat(mcp): add session manager with ETS-backed TTL"
```

---

### Task 3: MCP Tool Registry

This is the central registry of all 45 tool definitions with their JSON Schema input specs.

**Files:**
- Create: `lib/kudzu_web/mcp/tools.ex`
- Test: `test/kudzu_web/mcp/tools_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu_web/mcp/tools_test.exs
defmodule KudzuWeb.MCP.ToolsTest do
  use ExUnit.Case, async: true
  alias KudzuWeb.MCP.Tools

  test "list returns all tool definitions" do
    tools = Tools.list()
    assert is_list(tools)
    assert length(tools) > 40
    assert Enum.all?(tools, fn t -> Map.has_key?(t, :name) end)
    assert Enum.all?(tools, fn t -> Map.has_key?(t, :description) end)
    assert Enum.all?(tools, fn t -> Map.has_key?(t, :inputSchema) end)
  end

  test "all tool names are prefixed with kudzu_" do
    tools = Tools.list()
    assert Enum.all?(tools, fn t -> String.starts_with?(t.name, "kudzu_") end)
  end

  test "all tool names are unique" do
    tools = Tools.list()
    names = Enum.map(tools, & &1.name)
    assert names == Enum.uniq(names)
  end

  test "lookup finds a tool by name" do
    assert {:ok, tool} = Tools.lookup("kudzu_health")
    assert tool.name == "kudzu_health"
  end

  test "lookup returns error for unknown tool" do
    assert {:error, :not_found} = Tools.lookup("unknown_tool")
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/tools_test.exs`
Expected: FAIL

**Step 3: Write implementation**

```elixir
# lib/kudzu_web/mcp/tools.ex
defmodule KudzuWeb.MCP.Tools do
  @moduledoc "Registry of MCP tool definitions for all Kudzu operations."

  @tools [
    # === System ===
    %{
      name: "kudzu_health",
      description: "Health check. Returns status, node info, hologram count, Ollama availability.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },

    # === Hologram Management ===
    %{
      name: "kudzu_list_holograms",
      description: "List all active holograms with their ID, purpose, constitution, trace count, and peer count.",
      inputSchema: %{type: "object", properties: %{limit: %{type: "integer", description: "Max results (default 100)"}}, required: []}
    },
    %{
      name: "kudzu_create_hologram",
      description: "Create a new hologram. Returns its ID.",
      inputSchema: %{type: "object", properties: %{
        purpose: %{type: "string", description: "Hologram purpose (e.g. researcher, assistant)"},
        constitution: %{type: "string", description: "Constitutional framework: mesh_republic, cautious, open, kudzu_evolve"},
        desires: %{type: "array", items: %{type: "string"}, description: "Initial desires"},
        cognition: %{type: "boolean", description: "Enable LLM cognition"}
      }, required: []}
    },
    %{
      name: "kudzu_get_hologram",
      description: "Get detailed info about a specific hologram by ID.",
      inputSchema: %{type: "object", properties: %{id: %{type: "string", description: "Hologram ID"}}, required: ["id"]}
    },
    %{
      name: "kudzu_delete_hologram",
      description: "Stop and delete a hologram by ID.",
      inputSchema: %{type: "object", properties: %{id: %{type: "string", description: "Hologram ID"}}, required: ["id"]}
    },
    %{
      name: "kudzu_stimulate_hologram",
      description: "Send a stimulus to a hologram for LLM cognition. Returns the response and any actions taken.",
      inputSchema: %{type: "object", properties: %{
        id: %{type: "string", description: "Hologram ID"},
        stimulus: %{type: "string", description: "The prompt/stimulus text"},
        model: %{type: "string", description: "LLM model override"},
        timeout: %{type: "integer", description: "Timeout in ms (default 120000)"}
      }, required: ["id", "stimulus"]}
    },
    %{
      name: "kudzu_hologram_traces",
      description: "Query traces recorded by a hologram. Optionally filter by purpose.",
      inputSchema: %{type: "object", properties: %{
        id: %{type: "string", description: "Hologram ID"},
        purpose: %{type: "string", description: "Filter by purpose: observation, thought, memory, discovery, research, learning, session_context"},
        limit: %{type: "integer", description: "Max results (default 100)"}
      }, required: ["id"]}
    },
    %{
      name: "kudzu_record_trace",
      description: "Record a new trace on a hologram.",
      inputSchema: %{type: "object", properties: %{
        id: %{type: "string", description: "Hologram ID"},
        purpose: %{type: "string", description: "Trace purpose: observation, thought, memory, discovery, research, learning, session_context"},
        data: %{type: "object", description: "Trace data (freeform JSON)"}
      }, required: ["id", "purpose", "data"]}
    },
    %{
      name: "kudzu_hologram_peers",
      description: "List peers of a hologram with trust scores.",
      inputSchema: %{type: "object", properties: %{id: %{type: "string", description: "Hologram ID"}}, required: ["id"]}
    },
    %{
      name: "kudzu_add_hologram_peer",
      description: "Connect two holograms as peers.",
      inputSchema: %{type: "object", properties: %{
        id: %{type: "string", description: "Hologram ID"},
        peer_id: %{type: "string", description: "Peer hologram ID"}
      }, required: ["id", "peer_id"]}
    },
    %{
      name: "kudzu_get_hologram_constitution",
      description: "Get a hologram's constitutional framework and its principles.",
      inputSchema: %{type: "object", properties: %{id: %{type: "string", description: "Hologram ID"}}, required: ["id"]}
    },
    %{
      name: "kudzu_set_hologram_constitution",
      description: "Set a hologram's constitutional framework.",
      inputSchema: %{type: "object", properties: %{
        id: %{type: "string", description: "Hologram ID"},
        constitution: %{type: "string", description: "Framework: mesh_republic, cautious, open, kudzu_evolve"}
      }, required: ["id", "constitution"]}
    },
    %{
      name: "kudzu_get_hologram_desires",
      description: "Get a hologram's current desires.",
      inputSchema: %{type: "object", properties: %{id: %{type: "string", description: "Hologram ID"}}, required: ["id"]}
    },
    %{
      name: "kudzu_add_hologram_desire",
      description: "Add a desire to a hologram.",
      inputSchema: %{type: "object", properties: %{
        id: %{type: "string", description: "Hologram ID"},
        desire: %{type: "string", description: "The desire to add"}
      }, required: ["id", "desire"]}
    },

    # === Traces ===
    %{
      name: "kudzu_list_traces",
      description: "Query all traces across all holograms. Optionally filter by purpose.",
      inputSchema: %{type: "object", properties: %{
        purpose: %{type: "string", description: "Filter by purpose"},
        limit: %{type: "integer", description: "Max results (default 100)"}
      }, required: []}
    },
    %{
      name: "kudzu_get_trace",
      description: "Get a specific trace by ID.",
      inputSchema: %{type: "object", properties: %{id: %{type: "string", description: "Trace ID"}}, required: ["id"]}
    },
    %{
      name: "kudzu_share_trace",
      description: "Share a trace from one hologram to another.",
      inputSchema: %{type: "object", properties: %{
        trace_id: %{type: "string", description: "Trace ID to share"},
        from_id: %{type: "string", description: "Source hologram ID"},
        to_id: %{type: "string", description: "Target hologram ID"}
      }, required: ["trace_id", "from_id", "to_id"]}
    },

    # === Agents ===
    %{
      name: "kudzu_create_agent",
      description: "Create a named agent with optional desires and cognition.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        desires: %{type: "array", items: %{type: "string"}, description: "Initial desires"},
        cognition: %{type: "boolean", description: "Enable LLM cognition"},
        constitution: %{type: "string", description: "Constitutional framework"}
      }, required: ["name"]}
    },
    %{
      name: "kudzu_get_agent",
      description: "Find an agent by name and return its info.",
      inputSchema: %{type: "object", properties: %{name: %{type: "string", description: "Agent name"}}, required: ["name"]}
    },
    %{
      name: "kudzu_delete_agent",
      description: "Destroy an agent by name.",
      inputSchema: %{type: "object", properties: %{name: %{type: "string", description: "Agent name"}}, required: ["name"]}
    },
    %{
      name: "kudzu_agent_remember",
      description: "Store a memory for an agent.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        content: %{type: "string", description: "Memory content"},
        importance: %{type: "string", description: "Importance: low, normal, high, critical"},
        context: %{type: "string", description: "Additional context"}
      }, required: ["name", "content"]}
    },
    %{
      name: "kudzu_agent_learn",
      description: "Record a learning pattern for an agent.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        pattern: %{type: "string", description: "Pattern description"},
        examples: %{type: "array", items: %{type: "string"}, description: "Examples"},
        confidence: %{type: "number", description: "Confidence 0.0-1.0"}
      }, required: ["name", "pattern"]}
    },
    %{
      name: "kudzu_agent_think",
      description: "Record a thought for an agent.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        thought: %{type: "string", description: "The thought"}
      }, required: ["name", "thought"]}
    },
    %{
      name: "kudzu_agent_observe",
      description: "Record an observation for an agent.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        observation: %{type: "string", description: "What was observed"},
        source: %{type: "string", description: "Source of observation"},
        confidence: %{type: "number", description: "Confidence 0.0-1.0"}
      }, required: ["name", "observation"]}
    },
    %{
      name: "kudzu_agent_decide",
      description: "Record a decision with rationale for an agent.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        decision: %{type: "string", description: "The decision"},
        rationale: %{type: "string", description: "Why this decision"},
        alternatives: %{type: "array", items: %{type: "string"}, description: "Alternatives considered"},
        context: %{type: "string", description: "Decision context"}
      }, required: ["name", "decision", "rationale"]}
    },
    %{
      name: "kudzu_agent_recall",
      description: "Recall an agent's memories. Optionally filter by purpose or query string.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        purpose: %{type: "string", description: "Filter by purpose: memory, learning, thought, observation, decision, discovery"},
        query: %{type: "string", description: "Search query"},
        limit: %{type: "integer", description: "Max results"},
        include_mesh: %{type: "boolean", description: "Include mesh-distributed memories"}
      }, required: ["name"]}
    },
    %{
      name: "kudzu_agent_stimulate",
      description: "Send a prompt to an agent for LLM cognition. Requires cognition to be enabled.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        prompt: %{type: "string", description: "Stimulus/prompt text"}
      }, required: ["name", "prompt"]}
    },
    %{
      name: "kudzu_agent_desires",
      description: "Get an agent's current desires.",
      inputSchema: %{type: "object", properties: %{name: %{type: "string", description: "Agent name"}}, required: ["name"]}
    },
    %{
      name: "kudzu_agent_add_desire",
      description: "Add a desire to an agent.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        desire: %{type: "string", description: "The desire to add"}
      }, required: ["name", "desire"]}
    },
    %{
      name: "kudzu_agent_peers",
      description: "List an agent's peers.",
      inputSchema: %{type: "object", properties: %{name: %{type: "string", description: "Agent name"}}, required: ["name"]}
    },
    %{
      name: "kudzu_agent_connect_peer",
      description: "Connect an agent to a peer by name or hologram ID.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Agent name"},
        peer_name: %{type: "string", description: "Peer agent name"},
        peer_id: %{type: "string", description: "Peer hologram ID (alternative to peer_name)"}
      }, required: ["name"]}
    },

    # === Constitutions ===
    %{
      name: "kudzu_list_constitutions",
      description: "List all available constitutional frameworks.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "kudzu_get_constitution_details",
      description: "Get details and principles of a specific constitutional framework.",
      inputSchema: %{type: "object", properties: %{name: %{type: "string", description: "Framework name: mesh_republic, cautious, open, kudzu_evolve"}}, required: ["name"]}
    },
    %{
      name: "kudzu_check_constitution",
      description: "Check if an action is permitted under a constitutional framework.",
      inputSchema: %{type: "object", properties: %{
        name: %{type: "string", description: "Framework name"},
        action: %{type: "string", description: "Action to check"},
        context: %{type: "object", description: "Action context"}
      }, required: ["name", "action"]}
    },

    # === Cluster ===
    %{
      name: "kudzu_cluster_status",
      description: "Get cluster overview: node, distributed status, connected nodes.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "kudzu_cluster_nodes",
      description: "List all nodes in the cluster.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "kudzu_cluster_connect",
      description: "Connect to a remote cluster node.",
      inputSchema: %{type: "object", properties: %{node: %{type: "string", description: "Node name (e.g. kudzu@host)"}}, required: ["node"]}
    },
    %{
      name: "kudzu_cluster_stats",
      description: "Get cluster-wide statistics.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },

    # === Node/Mesh ===
    %{
      name: "kudzu_node_status",
      description: "Get local node status: ID, data dir, mesh status, peers, storage stats, capabilities.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "kudzu_node_init",
      description: "Initialize the local node for mesh networking.",
      inputSchema: %{type: "object", properties: %{
        data_dir: %{type: "string", description: "Data directory path"},
        node_name: %{type: "string", description: "Node name"}
      }, required: []}
    },
    %{
      name: "kudzu_mesh_create",
      description: "Create a new mesh network.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "kudzu_mesh_join",
      description: "Join an existing mesh network.",
      inputSchema: %{type: "object", properties: %{node: %{type: "string", description: "Node to join"}}, required: ["node"]}
    },
    %{
      name: "kudzu_mesh_leave",
      description: "Leave the current mesh network.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "kudzu_mesh_peers",
      description: "List all peers in the mesh.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "kudzu_node_capabilities",
      description: "Get local node capabilities.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },

    # === Beamlets ===
    %{
      name: "kudzu_list_beamlets",
      description: "List all beamlets (lightweight workers) and their capabilities.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "kudzu_get_beamlet",
      description: "Get details of a specific beamlet.",
      inputSchema: %{type: "object", properties: %{id: %{type: "string", description: "Beamlet ID"}}, required: ["id"]}
    },
    %{
      name: "kudzu_find_beamlets",
      description: "Find beamlets by capability (e.g. file_read, http_get, dns_resolve).",
      inputSchema: %{type: "object", properties: %{capability: %{type: "string", description: "Capability to search for"}}, required: ["capability"]}
    }
  ]

  def list, do: @tools

  def lookup(name) do
    case Enum.find(@tools, fn t -> t.name == name end) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/tools_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
cd /home/eel/claude/kudzu_src && git add lib/kudzu_web/mcp/tools.ex test/kudzu_web/mcp/tools_test.exs
git commit -m "feat(mcp): add tool registry with 45 tool definitions"
```

---

### Task 4: MCP Tool Handlers — System, Hologram, Traces

**Files:**
- Create: `lib/kudzu_web/mcp/handlers/system.ex`
- Create: `lib/kudzu_web/mcp/handlers/hologram.ex`
- Create: `lib/kudzu_web/mcp/handlers/trace.ex`
- Test: `test/kudzu_web/mcp/handlers_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu_web/mcp/handlers_test.exs
defmodule KudzuWeb.MCP.HandlersTest do
  use ExUnit.Case, async: false

  alias KudzuWeb.MCP.Handlers.{System, Hologram, Trace}

  test "system health returns status ok" do
    {:ok, result} = System.handle("kudzu_health", %{})
    assert result.status == "ok"
  end

  test "hologram list returns list" do
    {:ok, result} = Hologram.handle("kudzu_list_holograms", %{})
    assert is_list(result.holograms)
  end

  test "hologram create and get" do
    {:ok, created} = Hologram.handle("kudzu_create_hologram", %{"purpose" => "test_mcp"})
    assert created.id
    {:ok, got} = Hologram.handle("kudzu_get_hologram", %{"id" => created.id})
    assert got.id == created.id
  end

  test "trace list returns list" do
    {:ok, result} = Trace.handle("kudzu_list_traces", %{})
    assert is_list(result.traces)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/handlers_test.exs`
Expected: FAIL

**Step 3: Write implementations**

```elixir
# lib/kudzu_web/mcp/handlers/system.ex
defmodule KudzuWeb.MCP.Handlers.System do
  @moduledoc "MCP handler for system tools."

  def handle("kudzu_health", _params) do
    ollama_ok = try do
      case :httpc.request(:get, {~c"http://localhost:11434/api/tags", []}, [timeout: 2000], []) do
        {:ok, {{_, 200, _}, _, _}} -> true
        _ -> false
      end
    rescue
      _ -> false
    end

    {:ok, %{
      status: "ok",
      node: to_string(Node.self()),
      distributed: Node.alive?(),
      holograms: Kudzu.Application.hologram_count(),
      ollama: ollama_ok,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }}
  end
end
```

```elixir
# lib/kudzu_web/mcp/handlers/hologram.ex
defmodule KudzuWeb.MCP.Handlers.Hologram do
  @moduledoc "MCP handlers for hologram tools."

  alias Kudzu.{Application, Hologram, Constitution}

  @allowed_purposes ~w(api_spawned research assistant coordinator worker analyzer claude_memory claude_assistant claude_research claude_learning claude_project explorer thinker researcher librarian optimizer specialist)a
  @allowed_constitutions ~w(mesh_republic cautious open kudzu_evolve)a
  @allowed_trace_purposes ~w(observation thought memory discovery research learning session_context)a

  def handle("kudzu_list_holograms", params) do
    limit = Map.get(params, "limit", 100)
    holograms = Registry.select(Kudzu.Registry, [{{{:id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.take(limit)
    |> Enum.map(fn {id, pid} ->
      try do
        state = Hologram.get_state(pid)
        %{id: id, purpose: state.purpose, constitution: state.constitution,
          trace_count: map_size(state.traces), peer_count: map_size(state.peers)}
      rescue
        _ -> %{id: id, alive: false}
      end
    end)
    {:ok, %{holograms: holograms, count: length(holograms)}}
  end

  def handle("kudzu_create_hologram", params) do
    opts = [
      purpose: find_atom(params["purpose"], @allowed_purposes, :api_spawned),
      constitution: find_atom(params["constitution"], @allowed_constitutions, :mesh_republic),
      desires: Map.get(params, "desires", []),
      cognition: Map.get(params, "cognition", false)
    ]
    case Application.spawn_hologram(opts) do
      {:ok, pid} ->
        id = Hologram.get_id(pid)
        {:ok, %{id: id, purpose: opts[:purpose], constitution: opts[:constitution]}}
      {:error, reason} ->
        {:error, -32603, "Failed to spawn: #{inspect(reason)}"}
    end
  end

  def handle("kudzu_get_hologram", %{"id" => id}) do
    with_hologram(id, fn pid ->
      state = Hologram.get_state(pid)
      {:ok, %{id: state.id, purpose: state.purpose, constitution: state.constitution,
        desires: state.desires, trace_count: map_size(state.traces),
        peer_count: map_size(state.peers), cognition_enabled: state.cognition_enabled}}
    end)
  end

  def handle("kudzu_delete_hologram", %{"id" => id}) do
    with_hologram(id, fn pid ->
      GenServer.stop(pid, :normal)
      {:ok, %{deleted: true, id: id}}
    end)
  end

  def handle("kudzu_stimulate_hologram", %{"id" => id, "stimulus" => stimulus} = params) do
    with_hologram(id, fn pid ->
      opts = Enum.reject([
        timeout: Map.get(params, "timeout", 120_000),
        model: Map.get(params, "model")
      ], fn {_k, v} -> is_nil(v) end)
      case Hologram.stimulate(pid, stimulus, opts) do
        {:ok, response, actions} ->
          {:ok, %{response: response, actions: length(actions), hologram_id: id}}
        {:error, reason} ->
          {:error, -32603, "Stimulation failed: #{inspect(reason)}"}
      end
    end)
  end

  def handle("kudzu_hologram_traces", %{"id" => id} = params) do
    with_hologram(id, fn pid ->
      traces = Hologram.recall_all(pid)
      traces = if p = params["purpose"] do
        purpose_atom = find_atom(p, @allowed_trace_purposes, nil)
        if purpose_atom, do: Enum.filter(traces, &(&1.purpose == purpose_atom)), else: traces
      else
        traces
      end
      traces = Enum.take(traces, Map.get(params, "limit", 100))
      {:ok, %{traces: Enum.map(traces, &trace_to_map/1), count: length(traces)}}
    end)
  end

  def handle("kudzu_record_trace", %{"id" => id, "purpose" => purpose, "data" => data}) do
    with_hologram(id, fn pid ->
      purpose_atom = find_atom(purpose, @allowed_trace_purposes, :observation)
      case Hologram.record_trace(pid, purpose_atom, data) do
        {:ok, trace} -> {:ok, %{trace: trace_to_map(trace)}}
        {:error, reason} -> {:error, -32603, "Failed: #{inspect(reason)}"}
      end
    end)
  end

  def handle("kudzu_hologram_peers", %{"id" => id}) do
    with_hologram(id, fn pid ->
      state = Hologram.get_state(pid)
      peers = Enum.map(state.peers, fn {peer_id, info} ->
        %{id: peer_id, trust: info.trust, last_seen: info.last_seen}
      end)
      {:ok, %{peers: peers}}
    end)
  end

  def handle("kudzu_add_hologram_peer", %{"id" => id, "peer_id" => peer_id}) do
    with_hologram(id, fn pid ->
      case Registry.lookup(Kudzu.Registry, {:id, peer_id}) do
        [{peer_pid, _}] ->
          Hologram.introduce_peer(pid, peer_pid)
          {:ok, %{added: true, peer_id: peer_id}}
        [] ->
          {:error, -32602, "Peer hologram not found"}
      end
    end)
  end

  def handle("kudzu_get_hologram_constitution", %{"id" => id}) do
    with_hologram(id, fn pid ->
      constitution = Hologram.get_constitution(pid)
      principles = Constitution.principles(constitution)
      {:ok, %{constitution: constitution, principles: principles}}
    end)
  end

  def handle("kudzu_set_hologram_constitution", %{"id" => id, "constitution" => c}) do
    with_hologram(id, fn pid ->
      atom = find_atom(c, @allowed_constitutions, :mesh_republic)
      case Hologram.set_constitution(pid, atom) do
        :ok -> {:ok, %{updated: true, constitution: atom}}
        {:error, reason} -> {:error, -32603, "Failed: #{inspect(reason)}"}
      end
    end)
  end

  def handle("kudzu_get_hologram_desires", %{"id" => id}) do
    with_hologram(id, fn pid ->
      state = Hologram.get_state(pid)
      {:ok, %{desires: state.desires}}
    end)
  end

  def handle("kudzu_add_hologram_desire", %{"id" => id, "desire" => desire}) do
    with_hologram(id, fn pid ->
      Hologram.add_desire(pid, desire)
      {:ok, %{added: true, desire: desire}}
    end)
  end

  # -- Helpers --

  defp with_hologram(id, fun) do
    case Registry.lookup(Kudzu.Registry, {:id, id}) do
      [{pid, _}] -> fun.(pid)
      [] -> {:error, -32602, "Hologram not found: #{id}"}
    end
  end

  defp find_atom(nil, _allowed, default), do: default
  defp find_atom(str, allowed, default) when is_binary(str) do
    normalized = str |> String.trim() |> String.downcase()
    Enum.find(allowed, default, fn atom -> Atom.to_string(atom) == normalized end)
  end

  defp trace_to_map(%Kudzu.Trace{} = t) do
    %{id: t.id, origin: t.origin, purpose: t.purpose,
      path: t.path, reconstruction_hint: t.reconstruction_hint}
  end
  defp trace_to_map(t) when is_map(t), do: t
end
```

```elixir
# lib/kudzu_web/mcp/handlers/trace.ex
defmodule KudzuWeb.MCP.Handlers.Trace do
  @moduledoc "MCP handlers for trace tools."

  alias Kudzu.{Hologram, Application}

  def handle("kudzu_list_traces", params) do
    purpose_filter = params["purpose"]
    limit = Map.get(params, "limit", 100)

    traces = Application.list_holograms()
    |> Enum.flat_map(fn pid ->
      try do
        Hologram.recall_all(pid)
      rescue
        _ -> []
      end
    end)
    |> then(fn traces ->
      if purpose_filter do
        purpose_atom = String.to_existing_atom(purpose_filter)
        Enum.filter(traces, &(&1.purpose == purpose_atom))
      else
        traces
      end
    end)
    |> Enum.take(limit)

    {:ok, %{traces: Enum.map(traces, &trace_to_map/1), count: length(traces)}}
  rescue
    ArgumentError -> {:ok, %{traces: [], count: 0}}
  end

  def handle("kudzu_get_trace", %{"id" => trace_id}) do
    result = Application.list_holograms()
    |> Enum.find_value(fn pid ->
      try do
        Hologram.recall_all(pid) |> Enum.find(&(&1.id == trace_id))
      rescue
        _ -> nil
      end
    end)

    case result do
      nil -> {:error, -32602, "Trace not found: #{trace_id}"}
      trace -> {:ok, trace_to_map(trace)}
    end
  end

  def handle("kudzu_share_trace", %{"trace_id" => trace_id, "from_id" => from_id, "to_id" => to_id}) do
    with [{from_pid, _}] <- Registry.lookup(Kudzu.Registry, {:id, from_id}),
         [{to_pid, _}] <- Registry.lookup(Kudzu.Registry, {:id, to_id}) do
      trace = Hologram.recall_all(from_pid) |> Enum.find(&(&1.id == trace_id))
      if trace do
        Hologram.receive_trace(to_pid, trace, from_id)
        {:ok, %{shared: true, trace_id: trace_id, from: from_id, to: to_id}}
      else
        {:error, -32602, "Trace not found in source hologram"}
      end
    else
      _ -> {:error, -32602, "Hologram not found"}
    end
  end

  defp trace_to_map(%Kudzu.Trace{} = t) do
    %{id: t.id, origin: t.origin, purpose: t.purpose,
      path: t.path, reconstruction_hint: t.reconstruction_hint}
  end
  defp trace_to_map(t) when is_map(t), do: t
end
```

**Step 4: Run test to verify it passes**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/handlers_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
cd /home/eel/claude/kudzu_src && git add lib/kudzu_web/mcp/handlers/ test/kudzu_web/mcp/handlers_test.exs
git commit -m "feat(mcp): add system, hologram, and trace handlers"
```

---

### Task 5: MCP Tool Handlers — Agent, Constitution, Cluster, Node, Beamlet

**Files:**
- Create: `lib/kudzu_web/mcp/handlers/agent.ex`
- Create: `lib/kudzu_web/mcp/handlers/constitution.ex`
- Create: `lib/kudzu_web/mcp/handlers/cluster.ex`
- Create: `lib/kudzu_web/mcp/handlers/node.ex`
- Create: `lib/kudzu_web/mcp/handlers/beamlet.ex`

**Step 1: Write all handler modules**

```elixir
# lib/kudzu_web/mcp/handlers/agent.ex
defmodule KudzuWeb.MCP.Handlers.Agent do
  @moduledoc "MCP handlers for agent tools."

  alias Kudzu.Agent

  def handle("kudzu_create_agent", %{"name" => name} = params) do
    opts = []
    opts = if params["desires"], do: [{:desires, params["desires"]} | opts], else: opts
    opts = if params["cognition"], do: [{:cognition, params["cognition"]} | opts], else: opts
    opts = if params["constitution"], do: [{:constitution, String.to_atom(params["constitution"])} | opts], else: opts

    case Agent.create(name, opts) do
      {:ok, pid} -> {:ok, %{name: name, id: Agent.id(pid), status: "created"}}
      {:error, reason} -> {:error, -32603, "Failed: #{inspect(reason)}"}
    end
  end

  def handle("kudzu_get_agent", %{"name" => name}) do
    with_agent(name, fn pid -> {:ok, Agent.info(pid)} end)
  end

  def handle("kudzu_delete_agent", %{"name" => name}) do
    with_agent(name, fn pid ->
      Agent.destroy(pid)
      {:ok, %{status: "destroyed", name: name}}
    end)
  end

  def handle("kudzu_agent_remember", %{"name" => name, "content" => content} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["context"], do: [{:context, params["context"]} | opts], else: opts
      opts = if params["importance"], do: [{:importance, String.to_atom(params["importance"])} | opts], else: opts
      case Agent.remember(pid, content, opts) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "memory"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_learn", %{"name" => name, "pattern" => pattern} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["examples"], do: [{:examples, params["examples"]} | opts], else: opts
      opts = if params["confidence"], do: [{:confidence, params["confidence"]} | opts], else: opts
      case Agent.learn(pid, pattern, opts) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "learning"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_think", %{"name" => name, "thought" => thought}) do
    with_agent(name, fn pid ->
      case Agent.think(pid, thought) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "thought"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_observe", %{"name" => name, "observation" => observation} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["source"], do: [{:source, params["source"]} | opts], else: opts
      opts = if params["confidence"], do: [{:confidence, params["confidence"]} | opts], else: opts
      case Agent.observe(pid, observation, opts) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "observation"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_decide", %{"name" => name, "decision" => decision, "rationale" => rationale} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["alternatives"], do: [{:alternatives, params["alternatives"]} | opts], else: opts
      opts = if params["context"], do: [{:context, params["context"]} | opts], else: opts
      case Agent.decide(pid, decision, rationale, opts) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "decision"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_recall", %{"name" => name} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["limit"], do: [{:limit, params["limit"]} | opts], else: opts
      opts = if params["include_mesh"], do: [{:include_mesh, params["include_mesh"]} | opts], else: opts

      query = cond do
        params["purpose"] -> String.to_atom(params["purpose"])
        params["query"] -> params["query"]
        true -> ""
      end

      memories = Agent.recall(pid, query, opts)
      memories = if is_list(memories), do: memories, else: []
      {:ok, %{count: length(memories), memories: Enum.map(memories, &trace_to_map/1)}}
    end)
  end

  def handle("kudzu_agent_stimulate", %{"name" => name, "prompt" => prompt}) do
    with_agent(name, fn pid ->
      case Agent.stimulate(pid, prompt) do
        {:ok, response, actions} -> {:ok, %{response: response, actions: length(actions)}}
        {:ok, response} -> {:ok, %{response: response}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_desires", %{"name" => name}) do
    with_agent(name, fn pid -> {:ok, %{desires: Agent.desires(pid)}} end)
  end

  def handle("kudzu_agent_add_desire", %{"name" => name, "desire" => desire}) do
    with_agent(name, fn pid ->
      Agent.add_desire(pid, desire)
      {:ok, %{status: "added", desires: Agent.desires(pid)}}
    end)
  end

  def handle("kudzu_agent_peers", %{"name" => name}) do
    with_agent(name, fn pid ->
      info = Agent.info(pid)
      {:ok, %{peers: info.peers, peer_count: info.peer_count}}
    end)
  end

  def handle("kudzu_agent_connect_peer", %{"name" => name} = params) do
    with_agent(name, fn pid ->
      peer = cond do
        params["peer_id"] -> params["peer_id"]
        params["peer_name"] ->
          case Agent.find(params["peer_name"]) do
            {:ok, peer_pid} -> Agent.id(peer_pid)
            _ -> nil
          end
        true -> nil
      end

      if peer do
        Agent.connect(pid, peer)
        {:ok, %{status: "connected", peer: peer}}
      else
        {:error, -32602, "Peer not found"}
      end
    end)
  end

  defp with_agent(name, fun) do
    case Agent.find(name) do
      {:ok, pid} -> fun.(pid)
      {:error, :not_found} -> {:error, -32602, "Agent not found: #{name}"}
    end
  end

  defp trace_to_map(trace) when is_struct(trace, Kudzu.Trace) do
    %{id: trace.id, purpose: to_string(trace.purpose),
      reconstruction_hint: trace.reconstruction_hint,
      origin: trace.origin, path: trace.path}
  end
  defp trace_to_map(trace) when is_map(trace), do: trace
  defp trace_to_map(other), do: %{raw: inspect(other)}
end
```

```elixir
# lib/kudzu_web/mcp/handlers/constitution.ex
defmodule KudzuWeb.MCP.Handlers.Constitution do
  @moduledoc "MCP handlers for constitution tools."

  alias Kudzu.Constitution

  @frameworks ~w(mesh_republic cautious open kudzu_evolve)a

  def handle("kudzu_list_constitutions", _params) do
    frameworks = Enum.map(@frameworks, fn name ->
      %{name: name, principles: Constitution.principles(name)}
    end)
    {:ok, %{constitutions: frameworks}}
  end

  def handle("kudzu_get_constitution_details", %{"name" => name}) do
    atom = safe_atom(name)
    if atom in @frameworks do
      {:ok, %{name: atom, principles: Constitution.principles(atom)}}
    else
      {:error, -32602, "Unknown constitution: #{name}"}
    end
  end

  def handle("kudzu_check_constitution", %{"name" => name, "action" => action} = params) do
    atom = safe_atom(name)
    context = Map.get(params, "context", %{})
    if atom in @frameworks do
      action_tuple = {String.to_atom(action), context}
      result = Constitution.permitted?(atom, action_tuple, %{})
      {:ok, %{constitution: atom, action: action, result: format_decision(result)}}
    else
      {:error, -32602, "Unknown constitution: #{name}"}
    end
  end

  defp safe_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp format_decision(:permitted), do: "permitted"
  defp format_decision({:denied, reason}), do: "denied: #{reason}"
  defp format_decision({:requires_consensus, threshold}), do: "requires_consensus: #{threshold}"
end
```

```elixir
# lib/kudzu_web/mcp/handlers/cluster.ex
defmodule KudzuWeb.MCP.Handlers.Cluster do
  @moduledoc "MCP handlers for cluster tools."

  def handle("kudzu_cluster_status", _params) do
    {:ok, %{
      node: to_string(Node.self()),
      distributed: Node.alive?(),
      connected_nodes: Enum.map(Node.list(), &to_string/1),
      node_count: length(Node.list()) + 1
    }}
  end

  def handle("kudzu_cluster_nodes", _params) do
    nodes = [Node.self() | Node.list()] |> Enum.map(&to_string/1)
    {:ok, %{nodes: nodes}}
  end

  def handle("kudzu_cluster_connect", %{"node" => node_str}) do
    node = String.to_atom(node_str)
    case Node.connect(node) do
      true -> {:ok, %{connected: true, node: node_str}}
      false -> {:error, -32603, "Failed to connect to #{node_str}"}
      :ignored -> {:error, -32603, "Node not alive — start with --name or --sname"}
    end
  end

  def handle("kudzu_cluster_stats", _params) do
    {:ok, %{
      node: to_string(Node.self()),
      nodes: length(Node.list()) + 1,
      holograms: Kudzu.Application.hologram_count(),
      processes: length(Process.list()),
      memory_mb: Float.round(:erlang.memory(:total) / 1_048_576, 1)
    }}
  end
end
```

```elixir
# lib/kudzu_web/mcp/handlers/node.ex
defmodule KudzuWeb.MCP.Handlers.Node do
  @moduledoc "MCP handlers for node/mesh tools."

  def handle("kudzu_node_status", _params) do
    {:ok, Kudzu.Node.status()}
  end

  def handle("kudzu_node_init", params) do
    opts = []
    opts = if params["data_dir"], do: [{:data_dir, params["data_dir"]} | opts], else: opts
    opts = if params["node_name"], do: [{:node_name, params["node_name"]} | opts], else: opts
    case Kudzu.Node.init_node(opts) do
      :ok -> {:ok, %{status: "initialized"}}
      {:error, reason} -> {:error, -32603, inspect(reason)}
    end
  end

  def handle("kudzu_mesh_create", _params) do
    case Kudzu.Node.create_mesh() do
      :ok -> {:ok, %{status: "mesh_created"}}
      {:error, reason} -> {:error, -32603, inspect(reason)}
    end
  end

  def handle("kudzu_mesh_join", %{"node" => node_str}) do
    node = String.to_atom(node_str)
    case Kudzu.Node.join_mesh(node) do
      {:ok, status} -> {:ok, %{status: status}}
      {:error, reason} -> {:error, -32603, inspect(reason)}
    end
  end

  def handle("kudzu_mesh_leave", _params) do
    Kudzu.Node.leave_mesh()
    {:ok, %{status: "left_mesh"}}
  end

  def handle("kudzu_mesh_peers", _params) do
    {:ok, %{peers: Enum.map(Kudzu.Node.mesh_peers(), &to_string/1)}}
  end

  def handle("kudzu_node_capabilities", _params) do
    {:ok, Kudzu.Node.capabilities()}
  end
end
```

```elixir
# lib/kudzu_web/mcp/handlers/beamlet.ex
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
    # Beamlets are accessed by PID in the current implementation
    {:error, -32602, "Beamlet lookup by ID not supported — use kudzu_list_beamlets"}
  end

  def handle("kudzu_find_beamlets", %{"capability" => capability}) do
    # Check known capabilities
    known = ~w(file_read file_write http_get http_post dns_resolve schedule)
    if capability in known do
      {:ok, %{capability: capability, available: true}}
    else
      {:ok, %{capability: capability, available: false}}
    end
  end
end
```

**Step 2: Run all tests**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/`
Expected: PASS

**Step 3: Commit**

```bash
cd /home/eel/claude/kudzu_src && git add lib/kudzu_web/mcp/handlers/
git commit -m "feat(mcp): add agent, constitution, cluster, node, beamlet handlers"
```

---

### Task 6: MCP Controller (JSON-RPC Dispatch)

**Files:**
- Create: `lib/kudzu_web/mcp/controller.ex`
- Test: `test/kudzu_web/mcp/controller_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu_web/mcp/controller_test.exs
defmodule KudzuWeb.MCP.ControllerTest do
  use ExUnit.Case, async: false

  alias KudzuWeb.MCP.Controller

  setup do
    start_supervised!(KudzuWeb.MCP.Session)
    :ok
  end

  test "dispatch initialize returns capabilities" do
    {:response, result} = Controller.dispatch(
      {:request, "1", "initialize", %{"protocolVersion" => "2025-03-26"}}
    )
    assert result["result"]["protocolVersion"] == "2025-03-26"
    assert result["result"]["capabilities"]["tools"]
    assert result["result"]["serverInfo"]["name"] == "kudzu"
  end

  test "dispatch tools/list returns tools" do
    {:response, result} = Controller.dispatch(
      {:request, "2", "tools/list", %{}}
    )
    assert is_list(result["result"]["tools"])
    assert length(result["result"]["tools"]) > 40
  end

  test "dispatch tools/call for kudzu_health" do
    {:response, result} = Controller.dispatch(
      {:request, "3", "tools/call", %{"name" => "kudzu_health", "arguments" => %{}}}
    )
    assert result["result"]["content"]
    [content | _] = result["result"]["content"]
    assert content["type"] == "text"
  end

  test "dispatch initialized returns :accepted" do
    assert :accepted = Controller.dispatch({:notification, "initialized", %{}})
  end

  test "dispatch ping returns pong" do
    {:response, result} = Controller.dispatch({:request, "4", "ping", %{}})
    assert result["result"] == %{}
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/controller_test.exs`
Expected: FAIL

**Step 3: Write implementation**

```elixir
# lib/kudzu_web/mcp/controller.ex
defmodule KudzuWeb.MCP.Controller do
  @moduledoc "MCP JSON-RPC 2.0 dispatch controller."

  alias KudzuWeb.MCP.{Protocol, Tools, Session}
  alias KudzuWeb.MCP.Handlers.{System, Hologram, Trace, Agent, Constitution, Cluster, Node, Beamlet}

  @protocol_version "2025-03-26"

  @server_info %{
    "name" => "kudzu",
    "version" => "0.1.0"
  }

  @capabilities %{
    "tools" => %{"listChanged" => false}
  }

  @handler_map %{
    "kudzu_health" => System,
    "kudzu_list_holograms" => Hologram, "kudzu_create_hologram" => Hologram,
    "kudzu_get_hologram" => Hologram, "kudzu_delete_hologram" => Hologram,
    "kudzu_stimulate_hologram" => Hologram, "kudzu_hologram_traces" => Hologram,
    "kudzu_record_trace" => Hologram, "kudzu_hologram_peers" => Hologram,
    "kudzu_add_hologram_peer" => Hologram, "kudzu_get_hologram_constitution" => Hologram,
    "kudzu_set_hologram_constitution" => Hologram, "kudzu_get_hologram_desires" => Hologram,
    "kudzu_add_hologram_desire" => Hologram,
    "kudzu_list_traces" => Trace, "kudzu_get_trace" => Trace, "kudzu_share_trace" => Trace,
    "kudzu_create_agent" => Agent, "kudzu_get_agent" => Agent, "kudzu_delete_agent" => Agent,
    "kudzu_agent_remember" => Agent, "kudzu_agent_learn" => Agent, "kudzu_agent_think" => Agent,
    "kudzu_agent_observe" => Agent, "kudzu_agent_decide" => Agent, "kudzu_agent_recall" => Agent,
    "kudzu_agent_stimulate" => Agent, "kudzu_agent_desires" => Agent,
    "kudzu_agent_add_desire" => Agent, "kudzu_agent_peers" => Agent,
    "kudzu_agent_connect_peer" => Agent,
    "kudzu_list_constitutions" => Constitution, "kudzu_get_constitution_details" => Constitution,
    "kudzu_check_constitution" => Constitution,
    "kudzu_cluster_status" => Cluster, "kudzu_cluster_nodes" => Cluster,
    "kudzu_cluster_connect" => Cluster, "kudzu_cluster_stats" => Cluster,
    "kudzu_node_status" => Node, "kudzu_node_init" => Node,
    "kudzu_mesh_create" => Node, "kudzu_mesh_join" => Node,
    "kudzu_mesh_leave" => Node, "kudzu_mesh_peers" => Node,
    "kudzu_node_capabilities" => Node,
    "kudzu_list_beamlets" => Beamlet, "kudzu_get_beamlet" => Beamlet,
    "kudzu_find_beamlets" => Beamlet
  }

  # --- Public API ---

  def dispatch({:request, id, "initialize", params}) do
    result = %{
      "protocolVersion" => Map.get(params, "protocolVersion", @protocol_version),
      "capabilities" => @capabilities,
      "serverInfo" => @server_info
    }
    {:response, Protocol.encode_response(id, result)}
  end

  def dispatch({:request, id, "ping", _params}) do
    {:response, Protocol.encode_response(id, %{})}
  end

  def dispatch({:request, id, "tools/list", _params}) do
    tools = Tools.list() |> Enum.map(fn t ->
      %{"name" => t.name, "description" => t.description, "inputSchema" => t.inputSchema}
    end)
    {:response, Protocol.encode_response(id, %{"tools" => tools})}
  end

  def dispatch({:request, id, "tools/call", %{"name" => tool_name} = params}) do
    arguments = Map.get(params, "arguments", %{})

    case Map.get(@handler_map, tool_name) do
      nil ->
        {:response, Protocol.encode_error(id, -32602, "Unknown tool: #{tool_name}")}

      handler ->
        try do
          case handler.handle(tool_name, arguments) do
            {:ok, result} ->
              text = Jason.encode!(result, pretty: true)
              {:response, Protocol.encode_response(id, %{
                "content" => [%{"type" => "text", "text" => text}]
              })}

            {:error, code, message} ->
              {:response, Protocol.encode_response(id, %{
                "content" => [%{"type" => "text", "text" => "Error: #{message}"}],
                "isError" => true
              })}
          end
        rescue
          e ->
            {:response, Protocol.encode_response(id, %{
              "content" => [%{"type" => "text", "text" => "Internal error: #{inspect(e)}"}],
              "isError" => true
            })}
        end
    end
  end

  def dispatch({:request, id, method, _params}) do
    {:response, Protocol.encode_error(id, -32601, "Method not found: #{method}")}
  end

  def dispatch({:notification, "initialized", _params}) do
    :accepted
  end

  def dispatch({:notification, "notifications/cancelled", _params}) do
    :accepted
  end

  def dispatch({:notification, _method, _params}) do
    :accepted
  end

  def dispatch({:batch, items}) do
    results = Enum.map(items, &dispatch/1)
    responses = Enum.filter(results, fn
      {:response, _} -> true
      _ -> false
    end) |> Enum.map(fn {:response, r} -> r end)
    {:batch_response, responses}
  end
end
```

**Step 4: Run test to verify it passes**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/controller_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
cd /home/eel/claude/kudzu_src && git add lib/kudzu_web/mcp/controller.ex test/kudzu_web/mcp/controller_test.exs
git commit -m "feat(mcp): add JSON-RPC dispatch controller with tool routing"
```

---

### Task 7: MCP Router and Endpoint

**Files:**
- Create: `lib/kudzu_web/mcp/router.ex`
- Create: `lib/kudzu_web/mcp/endpoint.ex`
- Modify: `lib/kudzu/application.ex:22-54` (add to supervision tree)
- Modify: `config/config.exs` (add MCP endpoint config)

**Step 1: Write the MCP router (Plug-based, not Phoenix.Router)**

```elixir
# lib/kudzu_web/mcp/router.ex
defmodule KudzuWeb.MCP.Router do
  @moduledoc """
  Plug router for MCP Streamable HTTP.
  Handles POST, GET, DELETE on /mcp.
  """
  use Plug.Router

  alias KudzuWeb.MCP.{Protocol, Controller, Session}

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

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

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end
end
```

**Step 2: Write the MCP endpoint**

```elixir
# lib/kudzu_web/mcp/endpoint.ex
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
```

**Step 3: Add MCP config to config.exs**

Add after line 28 (after the existing `KudzuWeb.Endpoint` config):

```elixir
# MCP endpoint configuration (Tailscale-only)
# Override IP with KUDZU_MCP_IP env var
config :kudzu, KudzuWeb.MCP.Endpoint,
  http: [ip: {100, 70, 67, 110}, port: 4001],
  server: true,
  secret_key_base: "mcp-endpoint-does-not-use-sessions-but-phoenix-requires-this-key"
```

Also add env-specific overrides. In the `prod` block, add:

```elixir
  # MCP endpoint: use env vars for IP/port
  mcp_ip = System.get_env("KUDZU_MCP_IP", "100.70.67.110")
  |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  mcp_port = String.to_integer(System.get_env("KUDZU_MCP_PORT") || "4001")
  config :kudzu, KudzuWeb.MCP.Endpoint,
    http: [ip: mcp_ip, port: mcp_port]
```

In the `test` block, add:

```elixir
  config :kudzu, KudzuWeb.MCP.Endpoint,
    http: [port: 4003],
    server: false
```

**Step 4: Add to supervision tree in application.ex**

Add `KudzuWeb.MCP.Session` and `KudzuWeb.MCP.Endpoint` to the children list. Insert after `KudzuWeb.Endpoint` (line 50):

```elixir
      # MCP session manager
      KudzuWeb.MCP.Session,

      # MCP Streamable HTTP endpoint (Tailscale-only)
      KudzuWeb.MCP.Endpoint
```

**Step 5: Run all MCP tests**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/`
Expected: PASS

**Step 6: Commit**

```bash
cd /home/eel/claude/kudzu_src && git add lib/kudzu_web/mcp/router.ex lib/kudzu_web/mcp/endpoint.ex lib/kudzu/application.ex config/config.exs
git commit -m "feat(mcp): add MCP endpoint, router, and wire into supervision tree"
```

---

### Task 8: Integration Test

**Files:**
- Create: `test/kudzu_web/mcp/integration_test.exs`

**Step 1: Write integration test**

This test starts the full stack and makes HTTP requests to the MCP endpoint.

```elixir
# test/kudzu_web/mcp/integration_test.exs
defmodule KudzuWeb.MCP.IntegrationTest do
  use ExUnit.Case, async: false

  alias KudzuWeb.MCP.{Protocol, Controller, Session}

  setup do
    # Ensure session manager is running
    start_supervised!(Session)
    :ok
  end

  test "full MCP lifecycle: initialize, list tools, call tool" do
    # 1. Initialize
    {:response, init_resp} = Controller.dispatch(
      {:request, "1", "initialize", %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }}
    )
    assert init_resp["result"]["serverInfo"]["name"] == "kudzu"

    # 2. Initialized notification
    assert :accepted = Controller.dispatch({:notification, "initialized", %{}})

    # 3. List tools
    {:response, tools_resp} = Controller.dispatch({:request, "2", "tools/list", %{}})
    tools = tools_resp["result"]["tools"]
    assert length(tools) > 40
    names = Enum.map(tools, & &1["name"])
    assert "kudzu_health" in names
    assert "kudzu_create_agent" in names

    # 4. Call health tool
    {:response, health_resp} = Controller.dispatch(
      {:request, "3", "tools/call", %{"name" => "kudzu_health", "arguments" => %{}}}
    )
    [content | _] = health_resp["result"]["content"]
    assert content["type"] == "text"
    parsed = Jason.decode!(content["text"])
    assert parsed["status"] == "ok"

    # 5. Create and use an agent
    {:response, create_resp} = Controller.dispatch(
      {:request, "4", "tools/call", %{
        "name" => "kudzu_create_agent",
        "arguments" => %{"name" => "mcp_test_agent"}
      }}
    )
    [c | _] = create_resp["result"]["content"]
    agent_result = Jason.decode!(c["text"])
    assert agent_result["status"] == "created"

    # 6. Remember something
    {:response, _} = Controller.dispatch(
      {:request, "5", "tools/call", %{
        "name" => "kudzu_agent_remember",
        "arguments" => %{"name" => "mcp_test_agent", "content" => "MCP integration works"}
      }}
    )

    # 7. Recall
    {:response, recall_resp} = Controller.dispatch(
      {:request, "6", "tools/call", %{
        "name" => "kudzu_agent_recall",
        "arguments" => %{"name" => "mcp_test_agent"}
      }}
    )
    [rc | _] = recall_resp["result"]["content"]
    recall_result = Jason.decode!(rc["text"])
    assert recall_result["count"] >= 1

    # 8. Cleanup
    Controller.dispatch(
      {:request, "7", "tools/call", %{
        "name" => "kudzu_delete_agent",
        "arguments" => %{"name" => "mcp_test_agent"}
      }}
    )
  end
end
```

**Step 2: Run integration test**

Run: `cd /home/eel/claude/kudzu_src && mix test test/kudzu_web/mcp/integration_test.exs`
Expected: PASS

**Step 3: Run full test suite**

Run: `cd /home/eel/claude/kudzu_src && mix test`
Expected: PASS (no regressions)

**Step 4: Commit**

```bash
cd /home/eel/claude/kudzu_src && git add test/kudzu_web/mcp/integration_test.exs
git commit -m "test(mcp): add MCP integration test covering full lifecycle"
```

---

### Task 9: Deploy and Configure Claude Code

**Step 1: Rsync to titan**

```bash
rsync -avz --exclude '_build' --exclude 'deps' /home/eel/claude/kudzu_src/ titan:/home/eel/kudzu_src/
```

**Step 2: Compile on titan**

```bash
ssh titan "cd /home/eel/kudzu_src && mix deps.get && mix compile"
```

**Step 3: Restart Kudzu on titan**

```bash
ssh titan "kill \$(lsof -ti :4000); cd /home/eel/kudzu_src && elixir --erl '-detached' -S mix run --no-halt"
```

**Step 4: Verify MCP endpoint is listening**

```bash
ssh titan "sleep 3 && curl -s http://100.70.67.110:4001/mcp -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'"
```
Expected: JSON response with `protocolVersion`, `capabilities`, `serverInfo`

**Step 5: Verify from radiator via Tailscale**

```bash
curl -s http://100.70.67.110:4001/mcp -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```
Expected: Same JSON response, confirming Tailscale connectivity

**Step 6: Configure Claude Code MCP**

Create or update `/home/eel/claude/.mcp.json`:

```json
{
  "kudzu": {
    "type": "http",
    "url": "http://100.70.67.110:4001/mcp"
  }
}
```

**Step 7: Verify in Claude Code**

Restart Claude Code session. The MCP server should appear in the tool list. Test by asking Claude to call `kudzu_health`.

**Step 8: Commit config**

```bash
cd /home/eel/claude && git add .mcp.json
git commit -m "feat: configure Kudzu MCP server for Claude Code"
```
