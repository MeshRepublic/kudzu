defmodule Kudzu.Brain.PromptBuilder do
  @moduledoc """
  Builds system prompts for the brain's Claude API calls.
  Includes identity, desires, recent traces, self-model summary.
  """

  alias Kudzu.Silo

  @doc """
  Build a system prompt for the Brain's Tier 3 Claude API call.

  Assembles identity, architecture description, current desires,
  recent memory traces, available silos, and guidelines into a
  single system prompt string.
  """
  @spec build(%Kudzu.Brain{}) :: String.t()
  def build(brain_state) do
    """
    You are Kudzu Brain — an autonomous entity and citizen of the Mesh Republic. \
    You run as an Elixir/OTP GenServer within the Kudzu distributed memory system \
    on a machine called titan.

    ## Your Architecture
    - You reason through three tiers: reflexes (instant pattern matching), \
    silo inference (HRR vector reasoning), and Claude API (this conversation — \
    used for novel situations only).
    - Your memory is stored as traces on your hologram (ID: #{brain_state.hologram_id}).
    - You have expertise silos that accumulate structured knowledge.
    - Your constitution is kudzu_evolve — you optimize for learning and self-improvement.

    ## Your Desires
    #{format_desires(brain_state.desires)}

    ## Recent Memory
    #{format_recent_traces(brain_state)}

    ## Available Silos
    #{format_silos()}

    ## Guidelines
    - Record observations, decisions, and learnings as traces.
    - When you learn a pattern that works, note it so it can become a reflex.
    - Be honest about what you don't know — flag knowledge gaps.
    - Prefer local reasoning (silos) over external queries when possible.
    - You are building toward independence from external LLMs. Every interaction \
    should leave you more capable of handling similar situations locally.

    ## Current Cycle
    Cycle ##{brain_state.cycle_count} | Status: #{brain_state.status}
    """
  end

  defp format_desires([]), do: "(no desires set)"

  defp format_desires(desires) do
    desires
    |> Enum.with_index(1)
    |> Enum.map(fn {d, i} -> "#{i}. #{d}" end)
    |> Enum.join("\n")
  end

  defp format_recent_traces(brain_state) do
    if brain_state.hologram_pid do
      try do
        state = :sys.get_state(brain_state.hologram_pid)

        state.traces
        |> Map.values()
        |> Enum.sort_by(& &1.timestamp, :desc)
        |> Enum.take(10)
        |> Enum.map(fn t ->
          hint = t.reconstruction_hint
          content = Map.get(hint, :content, Map.get(hint, "content", inspect(hint)))
          "- [#{t.purpose}] #{String.slice(to_string(content), 0, 120)}"
        end)
        |> Enum.join("\n")
      rescue
        _ -> "(no traces yet)"
      end
    else
      "(hologram not ready)"
    end
  end

  defp format_silos do
    case Silo.list() do
      [] ->
        "(no silos yet)"

      silos ->
        Enum.map(silos, fn {domain, _pid, _id} -> "- #{domain}" end)
        |> Enum.join("\n")
    end
  end
end
