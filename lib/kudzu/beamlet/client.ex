defmodule Kudzu.Beamlet.Client do
  @moduledoc """
  Client interface for holograms to interact with beam-lets.

  Provides a clean API for purpose agents to delegate execution tasks
  to the beam-let substrate. Handles:
  - Capability discovery
  - Load-balanced routing
  - Fallback and retry logic
  - Proximity tracking
  """

  alias Kudzu.Beamlet.Supervisor, as: BeamletSup

  @retry_attempts 3
  @retry_delay_ms 100

  @doc """
  Execute an IO operation through the beam-let substrate.
  """
  def io(operation, from_id, opts \\ []) do
    capability = io_capability(operation)
    execute_with_retry(capability, operation, from_id, opts)
  end

  @doc """
  Read a file through IO beam-let.
  """
  def read_file(path, from_id) do
    io(%{op: :file_read, path: path}, from_id)
  end

  @doc """
  Write a file through IO beam-let.
  """
  def write_file(path, content, from_id) do
    io(%{op: :file_write, path: path, content: content}, from_id)
  end

  @doc """
  HTTP GET through IO beam-let.
  """
  def http_get(url, from_id, opts \\ []) do
    io(%{op: :http_get, url: url, headers: Keyword.get(opts, :headers, [])}, from_id)
  end

  @doc """
  HTTP POST through IO beam-let.
  """
  def http_post(url, body, from_id, opts \\ []) do
    io(%{
      op: :http_post,
      url: url,
      body: body,
      content_type: Keyword.get(opts, :content_type, "application/json"),
      headers: Keyword.get(opts, :headers, [])
    }, from_id)
  end

  @doc """
  Request scheduling hint from scheduler beam-let.
  """
  def get_priority(task_type, from_id) do
    execute(:scheduling, %{op: :get_priority_hint, task_type: task_type}, from_id)
  end

  @doc """
  Schedule work with priority.
  """
  def schedule_work(work, priority, from_id) do
    execute(:scheduling, %{op: :schedule_work, work: work, priority: priority}, from_id)
  end

  @doc """
  Find the best beam-let for a capability.
  """
  def find_beamlet(capability) do
    BeamletSup.find_best(capability)
  end

  @doc """
  Get all available beam-lets for a capability.
  """
  def list_beamlets(capability) do
    BeamletSup.find_by_capability(capability)
  end

  @doc """
  Check if a capability is available in the substrate.
  """
  def capability_available?(capability) do
    case BeamletSup.find_by_capability(capability) do
      [] -> false
      _ -> true
    end
  end

  @doc """
  Get beam-let substrate status.
  """
  def substrate_status do
    BeamletSup.status()
  end

  # Private

  defp execute(capability, request, from_id) do
    case BeamletSup.find_best(capability) do
      {:ok, pid} ->
        GenServer.call(pid, {:request, request, from_id}, 30_000)

      {:error, reason} ->
        {:error, {:no_beamlet, capability, reason}}
    end
  end

  defp execute_with_retry(capability, request, from_id, opts) do
    attempts = Keyword.get(opts, :retry_attempts, @retry_attempts)
    do_execute_with_retry(capability, request, from_id, attempts)
  end

  defp do_execute_with_retry(capability, request, from_id, attempts) when attempts > 0 do
    case execute(capability, request, from_id) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:no_beamlet, _, _}} = err ->
        # No point retrying if no beam-lets available
        err

      {:error, _reason} when attempts > 1 ->
        Process.sleep(@retry_delay_ms)
        do_execute_with_retry(capability, request, from_id, attempts - 1)

      error ->
        error
    end
  end

  defp do_execute_with_retry(capability, _request, _from_id, _attempts) do
    {:error, {:no_beamlet, capability, :exhausted_retries}}
  end

  defp io_capability(%{op: op}) do
    case op do
      :file_read -> :file_read
      :file_write -> :file_write
      :file_exists -> :file_read
      :file_list -> :file_read
      :http_get -> :http_get
      :http_post -> :http_post
      :shell_exec -> :shell_exec
      :dns_resolve -> :http_get
      _ -> :file_read  # default
    end
  end
end
