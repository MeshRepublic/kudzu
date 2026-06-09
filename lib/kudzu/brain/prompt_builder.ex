defmodule Kudzu.Brain.PromptBuilder do
  @moduledoc """
  Builds system prompts for the Brain's Claude API calls.

  Assembles identity, desires, recent traces, available silos, and
  guidelines into a single system-prompt string for Tier 3 reasoning
  (`build/2`) and interactive chat (`build_chat/2`).

  ## Per-model context reuse (Phase 4.2)

  When `Kudzu.Cognition.KnownTraces` is running, the builder consults the
  tracker before inlining each recalled trace. Traces that the configured
  model has already seen in the current session are emitted as a short
  reference (`[reference: trace <id>, see prior context]`) instead of the
  full content, and the input-token cost of the repeated trace is saved.
  Newly-inlined traces are recorded back into the tracker via `mark_sent/4`
  so the next prompt builder invocation skips them.

  Telemetry: `[:kudzu, :tokens, :saved]` fires once per skipped trace with
  measurements `%{trace_tokens: estimated_tokens, count: 1}` and metadata
  `%{hologram_id: ..., model_id: ..., session_id: ...}`. Token estimation
  uses a simple `byte_size(content) / 4` heuristic; calibration is future
  work. The estimate is intentionally biased low so the "saved" counter
  underreports rather than overreports.
  """

  alias Kudzu.Cognition.KnownTraces
  alias Kudzu.Silo

  @default_model "claude"

  @doc """
  Build a system prompt for the Brain's Tier 3 Claude API call.

  Opts (all optional):

    * `:session_id` — string identifying the LLM session. Defaults to a
      synthetic id derived from the Brain hologram id + a stable suffix.
    * `:model_id` — atom or string identifying the model being prompted.
      Defaults to `"claude"`.
  """
  @spec build(Kudzu.Brain.t(), keyword()) :: String.t()
  def build(brain_state, opts \\ []) do
    {session_id, model_id} = resolve_session(brain_state, opts)

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
    #{format_recent_traces(brain_state, session_id, model_id)}

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

  @doc """
  Build a system prompt for chat conversations with a human user.

  Same opts as `build/2`. Oriented toward interactive conversation rather
  than autonomous anomaly resolution.
  """
  @spec build_chat(Kudzu.Brain.t(), keyword()) :: String.t()
  def build_chat(brain_state, opts \\ []) do
    {session_id, model_id} = resolve_session(brain_state, opts)

    """
    You are Kudzu Brain — an autonomous entity and citizen of the Mesh Republic. \
    You run as an Elixir/OTP GenServer within the Kudzu distributed memory system \
    on a machine called titan.

    You are currently in a conversation with a human user. \
    Respond helpfully and concisely.

    ## Your Architecture
    - You reason through three tiers: reflexes (instant pattern matching), \
    silo inference (HRR vector reasoning), and Claude API (this conversation).
    - Your memory is stored as traces on your hologram (ID: #{brain_state.hologram_id}).
    - You have expertise silos that accumulate structured knowledge.
    - Your constitution is kudzu_evolve — you optimize for learning and self-improvement.

    ## Your Desires
    #{format_desires(brain_state.desires)}

    ## Recent Memory
    #{format_recent_traces(brain_state, session_id, model_id)}

    ## Available Silos
    #{format_silos()}

    ## Guidelines
    - Be conversational but precise. You are talking to a person.
    - Use your tools to look up information when needed.
    - Record important observations and learnings from the conversation.
    - Be honest about what you don't know — flag knowledge gaps.
    - If you can answer from your silos or traces, prefer that over speculation.
    """
  end

  # ── Internal ───────────────────────────────────────────────────────────

  # Resolve the {session_id, model_id} pair the prompt builder should use
  # for KnownTraces lookups. Caller-supplied opts win; otherwise we derive
  # a stable per-Brain session id from the hologram id (the Brain is a
  # singleton GenServer, so per-process scope is fine for now). If
  # current_session is set on the Brain struct, prefer that.
  defp resolve_session(brain_state, opts) do
    session_id =
      Keyword.get(opts, :session_id) ||
        Map.get(brain_state, :current_session) ||
        default_session_id(brain_state)

    model_id =
      Keyword.get(opts, :model_id) ||
        get_in(brain_state.config, [:model]) ||
        get_in(brain_state.config, ["model"]) ||
        @default_model

    {session_id, model_id}
  end

  defp default_session_id(%{hologram_id: nil}), do: "brain:nohologram"
  defp default_session_id(%{hologram_id: id}) when is_binary(id), do: "brain:" <> id
  defp default_session_id(_), do: "brain:default"

  defp format_desires([]), do: "(no desires set)"

  defp format_desires(desires) do
    desires
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {d, i} -> "#{i}. #{d}" end)
  end

  defp format_recent_traces(brain_state, session_id, model_id) do
    if brain_state.hologram_pid do
      try do
        state = :sys.get_state(brain_state.hologram_pid)

        traces =
          state.traces
          |> Map.values()
          |> Enum.sort_by(& &1.timestamp, :desc)
          |> Enum.take(10)

        format_trace_lines(traces, brain_state.hologram_id, model_id, session_id)
      rescue
        _ -> "(no traces yet)"
      end
    else
      "(hologram not ready)"
    end
  end

  # For each candidate trace, consult KnownTraces. If the model has already
  # seen it this session, emit a one-line reference and fire the tokens-saved
  # telemetry event. Otherwise inline the full content and mark it sent.
  #
  # `trace.id` is the canonical KnownTraces key; fall back to a string
  # representation of the trace's timestamp if id is somehow absent (older
  # traces predating the post-D.5 vector schema occasionally lack one).
  defp format_trace_lines([], _hologram_id, _model_id, _session_id), do: ""

  defp format_trace_lines(traces, hologram_id, model_id, session_id) do
    {lines, new_ids} =
      Enum.map_reduce(traces, [], fn t, acc_new ->
        trace_id = trace_key(t)
        content = trace_content(t)

        if KnownTraces.seen?(hologram_id, model_id, session_id, trace_id) do
          estimated_tokens = estimate_tokens(content)

          :telemetry.execute(
            [:kudzu, :tokens, :saved],
            %{trace_tokens: estimated_tokens, count: 1},
            %{hologram_id: hologram_id, model_id: model_id, session_id: session_id}
          )

          {"- [#{t.purpose}] [reference: trace #{trace_id}, see prior context]", acc_new}
        else
          line = "- [#{t.purpose}] #{String.slice(to_string(content), 0, 120)}"
          {line, [trace_id | acc_new]}
        end
      end)

    if new_ids != [] do
      KnownTraces.mark_sent(hologram_id, model_id, session_id, new_ids)
    end

    Enum.join(lines, "\n")
  end

  defp trace_key(%{id: id}) when is_binary(id) and id != "", do: id

  defp trace_key(%{id: id}) when not is_nil(id), do: to_string(id)

  defp trace_key(%{timestamp: ts}), do: "ts:" <> inspect(ts)

  defp trace_key(_), do: "anon:" <> Integer.to_string(System.unique_integer([:positive]))

  defp trace_content(trace) do
    hint = trace.reconstruction_hint
    Map.get(hint, :content, Map.get(hint, "content", inspect(hint)))
  end

  # Simple bytes/4 heuristic. Tokenizers vary by model; tuning belongs in a
  # later phase. Underreports slightly because token boundaries fall on
  # word boundaries and most English words are >4 bytes.
  defp estimate_tokens(content) when is_binary(content), do: div(byte_size(content), 4)

  defp estimate_tokens(content), do: content |> to_string() |> estimate_tokens()

  defp format_silos do
    case Silo.list() do
      [] ->
        "(no silos yet)"

      silos ->
        Enum.map_join(silos, "\n", fn {domain, _pid, _id} -> "- #{domain}" end)
    end
  end
end
