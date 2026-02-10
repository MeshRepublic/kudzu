defmodule KudzuWeb.Router do
  use Phoenix.Router
  import Plug.Conn
  import Phoenix.Controller

  pipeline :api do
    plug :accepts, ["json"]
    plug KudzuWeb.Plugs.APIAuth
  end

  # Health check - no auth required
  scope "/", KudzuWeb do
    get "/health", HealthController, :index
  end

  # API v1
  scope "/api/v1", KudzuWeb do
    pipe_through :api

    # Hologram management
    resources "/holograms", HologramController, except: [:new, :edit] do
      # Nested hologram actions
      post "/stimulate", HologramController, :stimulate
      get "/traces", HologramController, :traces
      post "/traces", HologramController, :record_trace
      get "/peers", HologramController, :peers
      post "/peers", HologramController, :add_peer
      get "/constitution", HologramController, :get_constitution
      put "/constitution", HologramController, :set_constitution
      get "/desires", HologramController, :get_desires
      post "/desires", HologramController, :add_desire
    end

    # Trace operations
    scope "/traces" do
      get "/", TraceController, :index
      get "/:id", TraceController, :show
      post "/share", TraceController, :share
    end

    # Constitution frameworks
    scope "/constitutions" do
      get "/", ConstitutionController, :index
      get "/:name", ConstitutionController, :show
      post "/:name/check", ConstitutionController, :check_permission
    end

    # Cluster/distributed operations
    scope "/cluster" do
      get "/", ClusterController, :index
      get "/nodes", ClusterController, :nodes
      post "/connect", ClusterController, :connect
      get "/stats", ClusterController, :stats
    end

    # Node/Mesh management (SETI-style distributed memory)
    scope "/node" do
      get "/", NodeController, :status
      post "/init", NodeController, :init
      post "/mesh/create", NodeController, :create_mesh
      post "/mesh/join", NodeController, :join_mesh
      post "/mesh/leave", NodeController, :leave_mesh
      get "/mesh/peers", NodeController, :mesh_peers
      get "/storage", NodeController, :storage_stats
      get "/capabilities", NodeController, :capabilities
    end

    # Universal Agent API (for any AI to use)
    scope "/agents" do
      post "/", AgentController, :create
      get "/:name", AgentController, :find
      delete "/:name", AgentController, :destroy

      # Memory operations
      post "/:name/remember", AgentController, :remember
      post "/:name/learn", AgentController, :learn
      post "/:name/think", AgentController, :think
      post "/:name/observe", AgentController, :observe
      post "/:name/decide", AgentController, :decide
      get "/:name/recall", AgentController, :recall
      get "/:name/recall/:purpose", AgentController, :recall_by_purpose

      # Cognition
      post "/:name/stimulate", AgentController, :stimulate
      get "/:name/desires", AgentController, :desires
      post "/:name/desires", AgentController, :add_desire

      # Peers
      get "/:name/peers", AgentController, :peers
      post "/:name/peers", AgentController, :connect_peer
    end

    # Beamlet operations
    scope "/beamlets" do
      get "/", BeamletController, :index
      get "/:id", BeamletController, :show
      get "/capabilities/:capability", BeamletController, :by_capability
    end
  end

  # Catch-all for 404
  match :*, "/*path", KudzuWeb.FallbackController, :not_found
end
