defmodule Kudzu.Beamlet.IO do
  @moduledoc """
  IO Beam-let - handles file system, network, and external API operations.

  Purpose holograms delegate all IO through this beam-let rather than
  performing it directly. This separation allows:
  - Centralized rate limiting and resource management
  - IO operation auditing and logging
  - Graceful degradation when IO substrate is unavailable
  - Hardware abstraction layer for future bare-metal deployment

  ## Security

  This module enforces strict security controls:
  - File operations are restricted to allowed paths (default: none)
  - HTTP operations block internal/private IPs and cloud metadata endpoints
  - Shell execution is DISABLED by default for security
  """

  use Kudzu.Beamlet.Base, capabilities: [:file_read, :file_write, :http_get, :http_post]

  require Logger

  # Default allowed paths - empty means no file access unless configured
  @default_allowed_paths []

  # Blocked IP ranges for SSRF protection
  @blocked_ip_patterns [
    ~r/^127\./,                          # Loopback
    ~r/^10\./,                           # Private Class A
    ~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./,  # Private Class B
    ~r/^192\.168\./,                     # Private Class C
    ~r/^169\.254\./,                     # Link-local / Cloud metadata
    ~r/^0\./,                            # Current network
    ~r/^localhost$/i,                    # Localhost hostname
    ~r/^.*\.internal$/i,                 # Internal domains
    ~r/^.*\.local$/i                     # Local domains
  ]

  @impl Kudzu.Beamlet.Behaviour
  def handle_request(%{op: :file_read, path: path}, from_id) do
    Logger.debug("IO Beamlet: file_read #{path} for #{from_id}")

    with :ok <- validate_path(path),
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      {:error, :path_not_allowed} ->
        Logger.warning("IO Beamlet: blocked file_read to disallowed path #{path}")
        {:error, :path_not_allowed}
      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  def handle_request(%{op: :file_write, path: path, content: content}, from_id) do
    Logger.debug("IO Beamlet: file_write #{path} for #{from_id}")

    with :ok <- validate_path(path),
         :ok <- File.write(path, content) do
      {:ok, :written}
    else
      {:error, :path_not_allowed} ->
        Logger.warning("IO Beamlet: blocked file_write to disallowed path #{path}")
        {:error, :path_not_allowed}
      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  def handle_request(%{op: :file_exists, path: path}, _from_id) do
    case validate_path(path) do
      :ok -> {:ok, File.exists?(path)}
      {:error, :path_not_allowed} -> {:error, :path_not_allowed}
    end
  end

  def handle_request(%{op: :file_list, path: path}, _from_id) do
    with :ok <- validate_path(path),
         {:ok, files} <- File.ls(path) do
      {:ok, files}
    else
      {:error, :path_not_allowed} -> {:error, :path_not_allowed}
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  def handle_request(%{op: :http_get, url: url} = req, from_id) do
    Logger.debug("IO Beamlet: http_get #{url} for #{from_id}")

    with :ok <- validate_url(url) do
      headers = Map.get(req, :headers, [])
      timeout = Map.get(req, :timeout, 30_000)

      :inets.start()
      :ssl.start()

      url_charlist = to_charlist(url)
      http_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

      case :httpc.request(:get, {url_charlist, http_headers}, [{:timeout, timeout}], []) do
        {:ok, {{_, status, _}, resp_headers, body}} ->
          {:ok, %{status: status, headers: resp_headers, body: to_string(body)}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    else
      {:error, reason} ->
        Logger.warning("IO Beamlet: blocked http_get to #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def handle_request(%{op: :http_post, url: url, body: body} = req, from_id) do
    Logger.debug("IO Beamlet: http_post #{url} for #{from_id}")

    with :ok <- validate_url(url) do
      content_type = Map.get(req, :content_type, "application/json")
      headers = Map.get(req, :headers, [])
      timeout = Map.get(req, :timeout, 30_000)

      :inets.start()
      :ssl.start()

      url_charlist = to_charlist(url)
      http_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

      request = {url_charlist, http_headers, to_charlist(content_type), body}

      case :httpc.request(:post, request, [{:timeout, timeout}], []) do
        {:ok, {{_, status, _}, resp_headers, resp_body}} ->
          {:ok, %{status: status, headers: resp_headers, body: to_string(resp_body)}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    else
      {:error, reason} ->
        Logger.warning("IO Beamlet: blocked http_post to #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Shell execution is DISABLED for security - command injection risk
  def handle_request(%{op: :shell_exec}, from_id) do
    Logger.warning("IO Beamlet: shell_exec DENIED for #{from_id} - disabled for security")
    {:error, :shell_exec_disabled}
  end

  def handle_request(%{op: :dns_resolve, hostname: hostname}, _from_id) do
    # Validate hostname doesn't resolve to internal IPs
    case :inet.gethostbyname(to_charlist(hostname)) do
      {:ok, {:hostent, _, _, _, _, addrs}} ->
        ips = Enum.map(addrs, &:inet.ntoa/1) |> Enum.map(&to_string/1)

        # Check if any resolved IP is internal
        if Enum.any?(ips, &internal_ip?/1) do
          Logger.warning("IO Beamlet: blocked dns_resolve for #{hostname} - resolves to internal IP")
          {:error, :internal_ip_blocked}
        else
          {:ok, ips}
        end

      {:error, reason} ->
        {:error, {:dns_error, reason}}
    end
  end

  def handle_request(req, from_id) do
    Logger.warning("IO Beamlet: unknown request #{inspect(req)} from #{from_id}")
    {:error, :unknown_operation}
  end

  # Initialize with security configuration
  def init_beamlet(state, opts) do
    allowed_paths = Keyword.get(opts, :allowed_paths, @default_allowed_paths)

    Map.merge(state, %{
      rate_limit: Keyword.get(opts, :rate_limit, 100),
      allowed_paths: allowed_paths,
      blocked_hosts: Keyword.get(opts, :blocked_hosts, [])
    })
  end

  # Security validation functions

  defp validate_path(path) do
    allowed_paths = get_allowed_paths()

    # Normalize path to prevent traversal attacks
    normalized = Path.expand(path)

    cond do
      # Empty allowlist means no file access
      allowed_paths == [] ->
        {:error, :path_not_allowed}

      # Check if path is under any allowed path
      Enum.any?(allowed_paths, fn allowed ->
        String.starts_with?(normalized, Path.expand(allowed))
      end) ->
        :ok

      true ->
        {:error, :path_not_allowed}
    end
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        cond do
          # Check against blocked patterns
          Enum.any?(@blocked_ip_patterns, &Regex.match?(&1, host)) ->
            {:error, :internal_url_blocked}

          # Additional check: try to resolve and verify IP
          internal_host?(host) ->
            {:error, :internal_url_blocked}

          true ->
            :ok
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  defp internal_ip?(ip) do
    Enum.any?(@blocked_ip_patterns, &Regex.match?(&1, ip))
  end

  defp internal_host?(host) do
    # Try to resolve the hostname and check if it's internal
    case :inet.gethostbyname(to_charlist(host)) do
      {:ok, {:hostent, _, _, _, _, addrs}} ->
        addrs
        |> Enum.map(&:inet.ntoa/1)
        |> Enum.map(&to_string/1)
        |> Enum.any?(&internal_ip?/1)

      _ ->
        # If we can't resolve, allow it (will fail at request time anyway)
        false
    end
  end

  defp get_allowed_paths do
    Application.get_env(:kudzu, :allowed_io_paths, @default_allowed_paths)
  end
end
