defmodule Kudzu.HTTP do
  @moduledoc """
  Centralized HTTP client with connection pooling.

  Starts a dedicated `:httpc` profile (`:kudzu_pool`) with keep-alive
  connection reuse so that repeated calls to Ollama, Claude API, and
  other HTTP endpoints don't pay TCP/TLS handshake costs on every request.

  ## Usage

      # At application startup (already wired into Application.start/2):
      Kudzu.HTTP.ensure_started()

      # For requests — drop-in replacement for :httpc.request/4:
      Kudzu.HTTP.request(:post, request_tuple, http_opts, opts)
      Kudzu.HTTP.request(:get, request_tuple, http_opts, opts)

  All existing `:httpc.request` call-sites should migrate to
  `Kudzu.HTTP.request/4` to benefit from connection reuse.
  """

  require Logger

  @profile :kudzu_pool
  @pool_opts [
    # Max simultaneous TCP connections to any single host
    max_sessions: 8,
    # Max requests queued on a single keep-alive connection
    max_keep_alive_length: 16,
    # Keep idle connections alive for 2 minutes
    keep_alive_timeout: 120_000,
    # Pipeline up to 4 requests on a single connection
    max_pipeline_length: 4,
    # Time to wait for a pipeline slot before opening a new connection
    pipeline_timeout: 5_000
  ]

  @doc """
  Ensure the pooled `:httpc` profile is started and configured.

  Safe to call multiple times — idempotent.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    # Start inets and ssl globally (idempotent)
    :inets.start()
    :ssl.start()

    # Start the named httpc profile if not already running
    case :inets.start(:httpc, [{:profile, @profile}]) do
      {:ok, _pid} ->
        configure_pool()
        Logger.info("[HTTP] Started connection pool profile :#{@profile}")
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("[HTTP] Failed to start pool profile: #{inspect(reason)}, using default")
        :ok
    end
  end

  @doc """
  Make an HTTP request using the pooled profile.

  Signature mirrors `:httpc.request/4` but routes through the connection pool.
  Falls back to the default profile if the pool isn't available.
  """
  @spec request(atom(), tuple(), keyword(), keyword()) ::
          {:ok, tuple()} | {:error, term()}
  def request(method, request, http_opts \\ [], opts \\ []) do
    profile = active_profile()
    :httpc.request(method, request, http_opts, opts, profile)
  end

  @doc """
  Returns the active httpc profile (:kudzu_pool if running, :default otherwise).
  """
  @spec active_profile() :: atom()
  def active_profile do
    case :httpc.info(@profile) do
      {:error, _} -> :default
      info when is_list(info) -> @profile
    end
  rescue
    _ -> :default
  end

  @doc """
  Return pool status information for diagnostics.
  """
  @spec pool_info() :: map()
  def pool_info do
    case :httpc.info(@profile) do
      info when is_list(info) ->
        %{
          profile: @profile,
          sessions: Keyword.get(info, :session_cookies, []) |> length(),
          profile_info: info
        }

      {:error, reason} ->
        %{profile: @profile, status: :not_running, reason: reason}
    end
  rescue
    _ -> %{profile: @profile, status: :error}
  end

  # Apply pool configuration to the profile
  defp configure_pool do
    :httpc.set_options(@pool_opts, @profile)
  end
end
