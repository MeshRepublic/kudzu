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
    },

    # === Semantic Memory ===
    %{
      name: "kudzu_semantic_recall",
      description: "Search traces by semantic similarity to a natural language query. Uses HRR token-seeded encoding with co-occurrence learning. Returns traces ranked by similarity.",
      inputSchema: %{type: "object", properties: %{
        query: %{type: "string", description: "Natural language query (e.g. 'supervisor crash restart')"},
        purpose: %{type: "string", description: "Filter by trace purpose: observation, thought, memory, discovery, research, learning, session_context"},
        limit: %{type: "integer", description: "Max results (default 10)"},
        threshold: %{type: "number", description: "Minimum similarity score 0.0-1.0 (default 0.0)"}
      }, required: ["query"]}
    },
    %{
      name: "kudzu_associations",
      description: "Show co-occurrence neighbors for a token. Reveals what concepts Kudzu has learned are related through trace processing.",
      inputSchema: %{type: "object", properties: %{
        token: %{type: "string", description: "Token to look up (e.g. 'supervisor', 'storage')"},
        k: %{type: "integer", description: "Number of neighbors (default 10)"}
      }, required: ["token"]}
    },
    %{
      name: "kudzu_vocabulary",
      description: "List known tokens and their frequency. Shows what concepts Kudzu has learned from processing traces.",
      inputSchema: %{type: "object", properties: %{
        limit: %{type: "integer", description: "Max results (default 50)"},
        query: %{type: "string", description: "Filter tokens containing this substring"}
      }, required: []}
    },
    %{
      name: "kudzu_encoder_stats",
      description: "Get HRR encoder statistics: vocabulary size, co-occurrence entries, traces processed, top tokens.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
  ]

  def list, do: @tools

  def lookup(name) do
    case Enum.find(@tools, fn t -> t.name == name end) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end
end
