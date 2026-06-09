defmodule Kudzu.Brain.Vectors.SystemIntrospector do
  @moduledoc """
  Learns about system tools and commands by running safe introspection commands.

  Uses SafeShell to execute man pages, --help, and which to discover
  information about system commands and tools.
  """

  @behaviour Kudzu.Brain.Vectors.Behaviour

  require Logger

  alias Kudzu.Brain.Tools.SafeShell

  @command_keywords ~w(command terminal bash shell linux man page
    systemctl apt install package cmd exec run)
  @tool_names ~w(grep sed awk find curl wget git ssh scp rsync tar
    make gcc python ruby node npm elixir mix iex erl epmd
    systemctl journalctl docker podman tmux screen vim nano
    ls cat head tail less file wc sort uniq cut tr diff
    ps top htop kill lsof netstat ss ip iptables mount umount
    df du free uname hostname date cal who whoami chmod chown)

  @impl true
  def name, do: :system_introspector

  @impl true
  def relevance(topic) do
    t = String.downcase(topic)

    # Check if the topic mentions a known command/tool
    tool_matches = Enum.count(@tool_names, &String.contains?(t, &1))
    keyword_matches = Enum.count(@command_keywords, &String.contains?(t, &1))

    cond do
      # Direct "man <cmd>" or "<cmd> --help" patterns
      Regex.match?(~r/\bman\s+\w+/, t) -> 0.9
      Regex.match?(~r/\b\w+\s+--help/, t) -> 0.85
      # Multiple tool matches = definitely system topic
      tool_matches >= 2 -> 0.8
      tool_matches == 1 -> 0.7
      # Keyword matches suggest system topic
      keyword_matches >= 2 -> 0.6
      keyword_matches == 1 -> 0.4
      true -> 0.1
    end
  end

  @impl true
  def available? do
    case SafeShell.execute("uname", ["-s"]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @impl true
  def learn(topic, _opts \\ []) do
    commands = plan_commands(topic)

    results =
      Enum.reduce(commands, [], fn {cmd, args, label}, acc ->
        case SafeShell.execute(cmd, args) do
          {:ok, output} when byte_size(output) > 10 ->
            [{label, output} | acc]

          _ ->
            acc
        end
      end)

    if results == [] do
      {:error, :no_useful_output}
    else
      content =
        results
        |> Enum.reverse()
        |> Enum.map_join("\n\n---\n\n", fn {label, output} ->
          "## #{label}\n\n#{String.slice(output, 0, 3000)}"
        end)

      {:ok,
       %{
         content: content,
         source: "system_introspection",
         confidence: 0.75,
         metadata: %{commands_run: length(results), commands_planned: length(commands)}
       }}
    end
  end

  # ── Command Planning ────────────────────────────────────────────

  defp plan_commands(topic) do
    t = String.downcase(topic)

    # Extract potential command names from topic
    cmd_names = extract_command_names(t)

    # Build command list based on extracted names
    commands =
      Enum.flat_map(cmd_names, fn cmd ->
        [
          {"man", [cmd], "Manual page: #{cmd}"},
          {"which", [cmd], "Location: #{cmd}"}
        ]
      end)

    # Add general system info if topic is broad
    commands =
      if Regex.match?(~r/\b(system|linux|os|kernel)\b/, t) do
        commands ++
          [
            {"uname", ["-a"], "System information"},
            {"uptime", [], "System uptime"},
            {"free", ["-h"], "Memory information"},
            {"df", ["-h"], "Disk information"}
          ]
      else
        commands
      end

    # Add Elixir/Erlang version if topic mentions them
    if Regex.match?(~r/\b(elixir|erlang|otp|beam)\b/, t) do
      commands ++
        [
          {"elixir", ["--version"], "Elixir version"},
          {"erl", ["-version"], "Erlang version"}
        ]
    else
      commands
    end
  end

  defp extract_command_names(topic) do
    # Find known tool names in the topic
    found = Enum.filter(@tool_names, &String.contains?(topic, &1))

    # Also try to extract command names from patterns like "man <cmd>" or "learn about <cmd>"
    pattern_matches =
      Regex.scan(~r/\b(?:man|about|learn|use|using)\s+(\w+)/, topic)
      |> Enum.map(fn [_, cmd] -> cmd end)
      |> Enum.filter(fn cmd ->
        # Only include if it looks like a command name (short, lowercase)
        byte_size(cmd) <= 20 and cmd == String.downcase(cmd)
      end)

    (found ++ pattern_matches)
    |> Enum.uniq()
    # Don't run too many commands
    |> Enum.take(5)
  end
end
