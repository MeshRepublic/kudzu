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
