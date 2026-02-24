defmodule Kudzu.Brain.Tools.Host do
  @moduledoc """
  Tier 2 tools: host system monitoring via shell commands.

  Provides three tools for inspecting the host system:

    * `check_disk`    — disk usage on all partitions
    * `check_memory`  — system memory usage (total, used, free, available)
    * `check_process` — check if a specific process is running by name
  """

  alias Kudzu.Brain.Tool

  # ── CheckDisk ─────────────────────────────────────────────────────

  defmodule CheckDisk do
    @moduledoc "Check disk usage on all partitions."
    @behaviour Tool

    @impl true
    def name, do: "check_disk"

    @impl true
    def description, do: "Check disk usage on all partitions. Returns percentage used per mount point."

    @impl true
    def parameters, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_params) do
      case System.cmd("df", ["-h", "--output=target,pcent,size,avail"], stderr_to_stdout: true) do
        {output, 0} ->
          lines = output |> String.trim() |> String.split("\n") |> Enum.drop(1)

          partitions =
            lines
            |> Enum.map(fn line ->
              parts = String.split(line, ~r/\s+/, trim: true)

              case parts do
                [mount, pct | rest] ->
                  %{
                    mount: mount,
                    used_percent: pct,
                    size: Enum.at(rest, 0),
                    available: Enum.at(rest, 1)
                  }

                _ ->
                  nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          {:ok, %{partitions: partitions}}

        {output, _code} ->
          {:error, "df failed: #{output}"}
      end
    end
  end

  # ── CheckMemory ───────────────────────────────────────────────────

  defmodule CheckMemory do
    @moduledoc "Check system memory usage."
    @behaviour Tool

    @impl true
    def name, do: "check_memory"

    @impl true
    def description, do: "Check system memory usage: total, used, free, available (in MB)."

    @impl true
    def parameters, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_params) do
      case System.cmd("free", ["-m"], stderr_to_stdout: true) do
        {output, 0} ->
          lines = String.split(output, "\n", trim: true)
          mem_line = Enum.find(lines, &String.starts_with?(&1, "Mem:"))

          if mem_line do
            parts = String.split(mem_line, ~r/\s+/, trim: true)

            {:ok,
             %{
               total_mb: Enum.at(parts, 1),
               used_mb: Enum.at(parts, 2),
               free_mb: Enum.at(parts, 3),
               available_mb: Enum.at(parts, 6)
             }}
          else
            {:error, "Could not parse memory info"}
          end

        {output, _code} ->
          {:error, "free failed: #{output}"}
      end
    end
  end

  # ── CheckProcess ──────────────────────────────────────────────────

  defmodule CheckProcess do
    @moduledoc "Check if a specific process is running by name."
    @behaviour Tool

    @impl true
    def name, do: "check_process"

    @impl true
    def description, do: "Check if a specific process is running by name."

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          name: %{
            type: "string",
            description: "Process name to search for (e.g. 'beam.smp', 'ollama')"
          }
        },
        required: ["name"]
      }
    end

    @impl true
    def execute(%{"name" => proc_name}) do
      case System.cmd("pgrep", ["-fl", proc_name], stderr_to_stdout: true) do
        {output, 0} ->
          processes = output |> String.trim() |> String.split("\n", trim: true)
          {:ok, %{running: true, count: length(processes), processes: processes}}

        {_output, 1} ->
          {:ok, %{running: false, count: 0, processes: []}}

        {output, _code} ->
          {:error, "pgrep failed: #{output}"}
      end
    end
  end

  # ── Module-Level Functions ────────────────────────────────────────

  @doc "Returns the list of all host tool modules."
  @spec all_tools() :: [module()]
  def all_tools, do: [CheckDisk, CheckMemory, CheckProcess]

  @doc "Converts all host tools to Claude API format."
  @spec to_claude_format() :: [map()]
  def to_claude_format do
    Enum.map(all_tools(), &Tool.to_claude_format/1)
  end

  @doc """
  Dispatch a tool call by name string.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec execute(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(name, params) do
    case Enum.find(all_tools(), fn mod -> mod.name() == name end) do
      nil -> {:error, "unknown host tool: #{name}"}
      mod -> mod.execute(params)
    end
  end
end
