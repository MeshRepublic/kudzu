defmodule Kudzu.Brain.Tools.SafeShell do
  @moduledoc """
  Sandboxed command execution for learning about the system.

  Strict allowlist of commands and arguments. Uses System.cmd/3
  (no shell interpretation) to prevent injection. Output capped at 10KB.
  """

  require Logger

  @max_output_bytes 10_240
  @timeout_ms 15_000

  @allowed_commands %{
    "man" => %{
      args_regex: ~r/\A[a-zA-Z0-9_.-]+\z/,
      max_args: 1,
      description: "Read manual pages"
    },
    "which" => %{
      args_regex: ~r/\A[a-zA-Z0-9_.-]+\z/,
      max_args: 1,
      description: "Locate a command"
    },
    "uname" => %{
      args_regex: ~r/\A-[a-z]+\z/,
      max_args: 1,
      description: "System information"
    },
    "uptime" => %{
      args_regex: nil,
      max_args: 0,
      description: "System uptime"
    },
    "df" => %{
      args_regex: ~r/\A-[a-zA-Z]+\z/,
      max_args: 2,
      description: "Disk usage"
    },
    "free" => %{
      args_regex: ~r/\A-[a-zA-Z]+\z/,
      max_args: 1,
      description: "Memory usage"
    },
    "head" => %{
      args_regex: ~r/\A(-n\s*\d+|[\/a-zA-Z0-9_.\-]+)\z/,
      max_args: 3,
      description: "Read first lines of a file"
    },
    "cat" => %{
      args_regex: nil,
      max_args: 1,
      description: "Read a file (path-restricted)"
    },
    "ls" => %{
      args_regex: nil,
      max_args: 2,
      description: "List directory contents (path-restricted)"
    },
    "elixir" => %{
      args_regex: ~r/\A--version\z/,
      max_args: 1,
      description: "Elixir version"
    },
    "erl" => %{
      args_regex: ~r/\A-version\z/,
      max_args: 1,
      description: "Erlang version"
    }
  }

  @allowed_read_paths [
    "/usr/share/doc",
    "/usr/share/man",
    "/etc",
    "/home/eel/kudzu_src/docs",
    "/home/eel/kudzu_src/lib",
    "/home/eel/kudzu_src/config",
    "/home/eel/kudzu_src/mix.exs",
    "/home/eel/kudzu_src/README.md"
  ]

  @path_commands ~w(cat ls head)

  @doc """
  Execute a command if it passes all validation checks.

  Returns `{:ok, output}` or `{:error, reason}`.
  """
  @spec execute(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def execute(command, args \\ []) do
    with :ok <- validate_command(command),
         :ok <- validate_args(command, args),
         :ok <- validate_paths(command, args) do
      run_command(command, args)
    end
  end

  @doc """
  List all allowed commands with descriptions.
  """
  @spec allowed_commands() :: [map()]
  def allowed_commands do
    Enum.map(@allowed_commands, fn {cmd, spec} ->
      %{command: cmd, description: spec.description, max_args: spec.max_args}
    end)
  end

  # ── Validation ──────────────────────────────────────────────────

  defp validate_command(command) do
    if Map.has_key?(@allowed_commands, command) do
      :ok
    else
      {:error, {:command_not_allowed, command}}
    end
  end

  defp validate_args(command, args) do
    spec = Map.fetch!(@allowed_commands, command)

    cond do
      length(args) > spec.max_args ->
        {:error, {:too_many_args, command, length(args), spec.max_args}}

      spec.args_regex != nil and args != [] ->
        invalid = Enum.reject(args, &Regex.match?(spec.args_regex, &1))

        if invalid == [] do
          :ok
        else
          {:error, {:invalid_args, command, invalid}}
        end

      true ->
        :ok
    end
  end

  defp validate_paths(command, args) when command in @path_commands do
    paths = Enum.filter(args, fn arg -> not String.starts_with?(arg, "-") end)

    if paths == [] do
      :ok
    else
      invalid = Enum.reject(paths, &path_allowed?/1)

      if invalid == [] do
        :ok
      else
        {:error, {:path_not_allowed, invalid}}
      end
    end
  end

  defp validate_paths(_command, _args), do: :ok

  defp path_allowed?(path) do
    expanded = Path.expand(path)
    # Prevent directory traversal
    not String.contains?(expanded, "..") and
      Enum.any?(@allowed_read_paths, fn allowed ->
        String.starts_with?(expanded, allowed)
      end)
  end

  # ── Execution ──────────────────────────────────────────────────

  defp run_command(command, args) do
    Logger.debug("[SafeShell] Executing: #{command} #{Enum.join(args, " ")}")

    task =
      Task.async(fn ->
        System.cmd(command, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        truncated = String.slice(output, 0, @max_output_bytes)

        if exit_code == 0 do
          {:ok, truncated}
        else
          {:error, {:exit_code, exit_code, truncated}}
        end

      nil ->
        {:error, :timeout}
    end
  rescue
    e ->
      {:error, {:execution_failed, Exception.message(e)}}
  end
end
