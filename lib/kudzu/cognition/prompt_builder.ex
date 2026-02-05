defmodule Kudzu.Cognition.PromptBuilder do
  @moduledoc """
  Builds prompts for hologram cognition from hologram state.

  Transforms traces, peers, and desires into LLM-digestible context.
  Constrains output format for reliable parsing.
  """

  @max_traces 20
  @max_peers 10

  @doc """
  Build a full cognition prompt from hologram state and stimulus.
  """
  @spec build(map(), String.t() | map()) :: String.t()
  def build(state, stimulus) do
    """
    You are a hologram agent in a distributed knowledge network called Kudzu.
    You exist to #{state.purpose || "navigate and preserve context"}.

    #{identity_section(state)}
    #{desires_section(state)}
    #{traces_section(state)}
    #{peers_section(state)}
    #{stimulus_section(stimulus)}
    #{action_format_section()}
    """
  end

  @doc """
  Build a quick/lightweight prompt for simple stimulus-response.
  """
  @spec build_quick(map(), String.t()) :: String.t()
  def build_quick(state, stimulus) do
    """
    You are hologram #{state.id}. Purpose: #{state.purpose || "general"}.
    #{if state.desires && state.desires != [], do: "Current desire: #{hd(state.desires)}", else: ""}

    Stimulus: #{stimulus}

    Respond with ONE action line:
    - RECORD_TRACE:purpose:key=value to remember something
    - QUERY_PEER:peer_id:purpose to ask a peer
    - RESPOND:message to reply
    - Or just describe your thought briefly

    Action:
    """
  end

  @doc """
  Build a collaboration prompt when multiple holograms need to coordinate.
  """
  @spec build_collaborative(map(), [map()], String.t()) :: String.t()
  def build_collaborative(state, peer_states, task) do
    """
    You are hologram #{state.id} coordinating with peers on a collective task.

    YOUR STATE:
    #{identity_section(state)}
    #{desires_section(state)}

    PEER STATES:
    #{peer_states_section(peer_states)}

    COLLECTIVE TASK: #{task}

    What is your role in accomplishing this task? What information do you have that others need?
    Who should you coordinate with?

    #{action_format_section()}
    """
  end

  # Private section builders

  defp identity_section(state) do
    """
    == IDENTITY ==
    ID: #{state.id}
    Purpose: #{state.purpose || "general navigation"}
    Traces held: #{map_size(state.traces || %{})}
    Peers known: #{map_size(state.peers || %{})}
    """
  end

  defp desires_section(%{desires: desires}) when is_list(desires) and desires != [] do
    desire_list = desires
    |> Enum.with_index(1)
    |> Enum.map(fn {d, i} -> "  #{i}. #{d}" end)
    |> Enum.join("\n")

    """
    == ACTIVE DESIRES ==
    What you are trying to achieve:
    #{desire_list}
    """
  end
  defp desires_section(_), do: ""

  defp traces_section(%{traces: traces}) when is_map(traces) and map_size(traces) > 0 do
    trace_summaries = traces
    |> Map.values()
    |> Enum.sort_by(& &1.timestamp, {:desc, Kudzu.VectorClock})
    |> Enum.take(@max_traces)
    |> Enum.map(&format_trace/1)
    |> Enum.join("\n")

    """
    == RECENT TRACES (your navigational memory) ==
    #{trace_summaries}
    """
  end
  defp traces_section(_), do: "== TRACES ==\nNo traces recorded yet.\n"

  defp format_trace(trace) do
    hints = trace.reconstruction_hint
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(", ")

    path_str = Enum.join(trace.path, " -> ")

    "  [#{trace.purpose}] #{hints} (path: #{path_str})"
  end

  defp peers_section(%{peers: peers}) when is_map(peers) and map_size(peers) > 0 do
    peer_list = peers
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.take(@max_peers)
    |> Enum.map(fn {id, score} ->
      proximity = cond do
        score > 0.8 -> "very close"
        score > 0.5 -> "close"
        score > 0.2 -> "moderate"
        true -> "distant"
      end
      "  #{id}: #{proximity} (#{Float.round(score, 2)})"
    end)
    |> Enum.join("\n")

    """
    == PEER AWARENESS ==
    Other holograms you can communicate with:
    #{peer_list}
    """
  end
  defp peers_section(_), do: "== PEERS ==\nNo peers known yet.\n"

  defp peer_states_section(peer_states) do
    peer_states
    |> Enum.map(fn ps ->
      """
      Peer #{ps.id}:
        Purpose: #{ps.purpose}
        Traces: #{map_size(ps.traces || %{})}
        Desires: #{inspect(ps.desires || [])}
      """
    end)
    |> Enum.join("\n")
  end

  defp stimulus_section(stimulus) when is_binary(stimulus) do
    """
    == STIMULUS ==
    You have received: #{stimulus}

    Consider: How does this relate to your purpose and desires?
    What traces are relevant? Should you involve peers?
    """
  end

  defp stimulus_section(%{type: type} = stimulus) do
    details = Map.drop(stimulus, [:type])
    |> Enum.map(fn {k, v} -> "  #{k}: #{inspect(v)}" end)
    |> Enum.join("\n")

    """
    == STIMULUS ==
    Type: #{type}
    #{details}

    Consider: How does this relate to your purpose and desires?
    """
  end

  defp stimulus_section(_), do: ""

  defp action_format_section do
    """
    == YOUR RESPONSE ==
    Think through the situation, then output actions. Use these formats:

    THOUGHT:your reasoning here (will be recorded as a trace)
    OBSERVATION:something you noticed
    RECORD_TRACE:purpose:key=value,key2=value2
    QUERY_PEER:peer_id:purpose
    SHARE_TRACE:peer_id:trace_id
    UPDATE_DESIRE:new goal or modified desire
    RESPOND:message to send back

    You may output multiple actions. Be concise but thorough.
    Remember: you preserve context through navigation, not storage.
    The trace is the path back to reconstruction.
    """
  end
end
