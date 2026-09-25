defmodule KudzuWeb.HologramSocket do
  @moduledoc """
  WebSocket entry point. Connections must present a valid API key as the
  `token` connect param; the key's scope (`:read` or `:mutate`) is assigned
  as `:api_scope` and enforced per join/event by `KudzuWeb.HologramChannel`.
  """
  use Phoenix.Socket

  alias KudzuWeb.Plugs.APIAuth

  channel("hologram:*", KudzuWeb.HologramChannel)

  @impl true
  def connect(params, socket, _connect_info) do
    case APIAuth.authorize_token(params["token"], :read) do
      {:ok, scope} -> {:ok, assign(socket, :api_scope, scope)}
      {:error, _status, _message} -> :error
    end
  end

  @impl true
  def id(_socket), do: nil
end
