defmodule KudzuWeb.Plugs.APIAuth do
  @moduledoc """
  Shared API key store and authentication plug.

  One key store backs every entry point: REST (`/api/v1`), MCP (`/mcp`),
  Brain chat, and the WebSocket (`/socket`).

  Every key carries exactly one scope:

    * `:read`   — list / get / check operations only
    * `:mutate` — everything `:read` may do, plus any state change

  Keys are populated at runtime from the environment (see
  `config/runtime.exs`):

    * `KUDZU_API_KEY`      — comma-separated mutate keys (mandatory)
    * `KUDZU_API_READ_KEY` — comma-separated read-only keys (optional)

  and stored as:

      config :kudzu, :api_auth, keys: %{"full-key" => :mutate, "ro-key" => :read}

  There is no "auth disabled" mode — a request without a valid key is
  always rejected.

  ## As a plug

      plug KudzuWeb.Plugs.APIAuth                 # scope from HTTP method
      plug KudzuWeb.Plugs.APIAuth, scope: :read   # explicit scope

  Without an explicit scope, GET/HEAD/OPTIONS require `:read` and every
  other method requires `:mutate`. On success the conn is assigned
  `:authenticated` and `:api_scope`; otherwise it is halted with 401
  (missing/invalid key) or 403 (insufficient scope).
  """

  import Plug.Conn

  @type scope :: :read | :mutate

  @read_methods ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(conn, opts) do
    required = Keyword.get_lazy(opts, :scope, fn -> scope_for_method(conn.method) end)

    case authorize(conn, required) do
      {:ok, scope} ->
        conn
        |> assign(:authenticated, true)
        |> assign(:api_scope, scope)

      {:error, status, message} ->
        conn
        |> deny(status, message)
        |> halt()
    end
  end

  @doc """
  Authenticate the bearer token on `conn` and check it grants `required`.

  Returns `{:ok, granted_scope}` or `{:error, http_status, message}`.
  """
  @spec authorize(Plug.Conn.t(), scope()) :: {:ok, scope()} | {:error, 401 | 403, String.t()}
  def authorize(conn, required) do
    case bearer_token(conn) do
      :error ->
        {:error, 401, "Authorization header required"}

      {:ok, token} ->
        authorize_token(token, required)
    end
  end

  @doc """
  Check a raw token (e.g. from WebSocket connect params) grants `required`.
  """
  @spec authorize_token(String.t() | nil, scope()) ::
          {:ok, scope()} | {:error, 401 | 403, String.t()}
  def authorize_token(token, required) do
    case scope_for_token(token) do
      :error ->
        {:error, 401, "Invalid API key"}

      {:ok, scope} ->
        if permits?(scope, required),
          do: {:ok, scope},
          else: {:error, 403, "API key scope '#{scope}' cannot perform '#{required}' operations"}
    end
  end

  @doc """
  Look up the scope of `token`. Compares against every configured key in
  constant time so the lookup does not leak key prefixes through timing.
  """
  @spec scope_for_token(term()) :: {:ok, scope()} | :error
  def scope_for_token(token) when is_binary(token) and token != "" do
    keys()
    |> Enum.reduce(:error, fn {key, scope}, acc ->
      if Plug.Crypto.secure_compare(key, token), do: {:ok, scope}, else: acc
    end)
  end

  def scope_for_token(_), do: :error

  @doc "Whether a key holding `have` may perform an operation needing `need`."
  @spec permits?(scope(), scope()) :: boolean()
  def permits?(:mutate, _need), do: true
  def permits?(:read, :read), do: true
  def permits?(_have, _need), do: false

  @doc "Required scope for an HTTP method when no explicit scope is given."
  @spec scope_for_method(String.t()) :: scope()
  def scope_for_method(method) when method in @read_methods, do: :read
  def scope_for_method(_method), do: :mutate

  defp keys do
    Application.get_env(:kudzu, :api_auth, [])
    |> Keyword.get(:keys) || %{}
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
  end
end
