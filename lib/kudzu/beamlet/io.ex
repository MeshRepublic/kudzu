defmodule Kudzu.Beamlet.IO do
  @moduledoc """
  IO Beam-let - handles file system, network, and external API operations.

  Purpose holograms delegate all IO through this beam-let rather than
  performing it directly. This separation allows:
  - Centralized rate limiting and resource management
  - IO operation auditing and logging
  - Graceful degradation when IO substrate is unavailable
  - Hardware abstraction layer for future bare-metal deployment
  """

  use Kudzu.Beamlet.Base, capabilities: [:file_read, :file_write, :http_get, :http_post, :shell_exec]

  require Logger

  @impl Kudzu.Beamlet.Behaviour
  def handle_request(%{op: :file_read, path: path}, from_id) do
    Logger.debug("IO Beamlet: file_read #{path} for #{from_id}")

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  def handle_request(%{op: :file_write, path: path, content: content}, from_id) do
    Logger.debug("IO Beamlet: file_write #{path} for #{from_id}")

    case File.write(path, content) do
      :ok -> {:ok, :written}
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  def handle_request(%{op: :file_exists, path: path}, _from_id) do
    {:ok, File.exists?(path)}
  end

  def handle_request(%{op: :file_list, path: path}, _from_id) do
    case File.ls(path) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  def handle_request(%{op: :http_get, url: url} = req, from_id) do
    Logger.debug("IO Beamlet: http_get #{url} for #{from_id}")

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
  end

  def handle_request(%{op: :http_post, url: url, body: body} = req, from_id) do
    Logger.debug("IO Beamlet: http_post #{url} for #{from_id}")

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
  end

  def handle_request(%{op: :shell_exec, cmd: cmd} = req, from_id) do
    Logger.debug("IO Beamlet: shell_exec for #{from_id}")

    timeout = Map.get(req, :timeout, 30_000)
    env = Map.get(req, :env, [])

    # Security: only allow certain commands or validate
    # For now, just execute with timeout
    try do
      {output, exit_code} = System.cmd("sh", ["-c", cmd],
        stderr_to_stdout: true,
        env: env
      )
      {:ok, %{output: output, exit_code: exit_code}}
    catch
      :error, reason -> {:error, {:shell_error, reason}}
    end
  end

  def handle_request(%{op: :dns_resolve, hostname: hostname}, _from_id) do
    case :inet.gethostbyname(to_charlist(hostname)) do
      {:ok, {:hostent, _, _, _, _, addrs}} ->
        ips = Enum.map(addrs, &:inet.ntoa/1) |> Enum.map(&to_string/1)
        {:ok, ips}

      {:error, reason} ->
        {:error, {:dns_error, reason}}
    end
  end

  def handle_request(req, from_id) do
    Logger.warning("IO Beamlet: unknown request #{inspect(req)} from #{from_id}")
    {:error, :unknown_operation}
  end

  # Initialize with any IO-specific state
  def init_beamlet(state, opts) do
    # Could set up connection pools, rate limiters, etc.
    Map.merge(state, %{
      rate_limit: Keyword.get(opts, :rate_limit, 100),  # requests per second
      allowed_paths: Keyword.get(opts, :allowed_paths, nil),  # nil = all allowed
      blocked_hosts: Keyword.get(opts, :blocked_hosts, [])
    })
  end
end
