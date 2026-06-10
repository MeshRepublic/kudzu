defmodule Kudzu.PromptBuilder do
  @moduledoc """
  Unified prompt assembly for every LLM in the Kudzu mesh.

  Replaces the previously separate `Kudzu.Brain.PromptBuilder` (Claude API
  path) and `Kudzu.Cognition.PromptBuilder` (Ollama hologram-stimulate
  path). One module owns:

    * state normalization (a `%Kudzu.Brain{}` struct, a hologram-state
      map, or any other LLM-context-bearing map all funnel through one
      `Context` representation),
    * `Kudzu.Cognition.KnownTraces` consultation — the per-session
      "have we already shown this trace to this model?" check that
      keeps repeat traces out of repeated prompts, and
    * format dispatch — adapters render the assembled context as prose
      (for Claude) or banner-delimited sections (for Ollama). The
      Ollama path also gets a stimulus block and the strict action
      grammar that `Kudzu.Cognition.parse_response/2` expects.

  ## Public API

  `build/3` is the only entry point most callers need. It accepts a
  caller-supplied state (any shape — Brain struct, hologram map, peer
  map for collaboration prompts), an optional message/stimulus string,
  and an opts keyword list:

    * `:format` — one of `:claude_reasoning` (Brain → Claude system
      prompt for autonomous tier-3 reasoning), `:claude_chat` (Brain →
      Claude system prompt for interactive chat), `:ollama_full`
      (`Kudzu.Cognition.think/3` Ollama prompt), `:ollama_quick`
      (`Kudzu.Cognition.quick_think/3` lightweight Ollama prompt), or
      `:ollama_collaborative` (multi-hologram coordination prompt).
      Required.
    * `:session_id` — LLM session id used by KnownTraces. Derived from
      caller state when omitted (e.g. `"brain:<hologram_id>"`).
    * `:model_id` — atom or string identifying the model. Derived from
      `state.config[:model]` (Brain) or `state.cognition_model`
      (Hologram) when omitted.
    * `:peer_states` — for `:ollama_collaborative`, the list of peer
      hologram-state maps.

  ## KnownTraces / tokens-saved telemetry

  Both Claude and Ollama formats consult
  `Kudzu.Cognition.KnownTraces.seen?/4` on every recalled trace. Traces
  the model has already seen this session are emitted as a short
  reference (`[reference: trace <id>, see prior context]`); traces it
  has not are inlined and `mark_sent/4` records them. Each skip emits
  `[:kudzu, :tokens, :saved]` telemetry with measurements
  `%{trace_tokens: estimated_tokens, count: 1}` and metadata
  `%{hologram_id: ..., model_id: ..., session_id: ...}`. Token estimation
  uses `byte_size(content) / 4` and intentionally underreports.

  Before Phase 4.3 the Ollama path bypassed KnownTraces entirely; the
  Brain path was instrumented during Phase 4.2. With unification, both
  LLM paths contribute to the tokens-saved counter.
  """

  alias Kudzu.Cognition.KnownTraces
  alias Kudzu.Silo

  @default_claude_model "claude"
  @default_ollama_model "ollama"
  @max_brain_traces 10
  @max_cognition_traces 20
  @max_peers 10

  @typedoc "All supported prompt formats."
  @type format ::
          :claude_reasoning
          | :claude_chat
          | :ollama_full
          | :ollama_quick
          | :ollama_collaborative

  @typedoc "Build options."
  @type opts :: [
          format: format(),
          session_id: String.t() | nil,
          model_id: String.t() | atom() | nil,
          peer_states: [map()]
        ]

  # Normalized internal representation. Every caller-shape funnels
  # through this struct before format adapters touch it.
  defmodule Context do
    @moduledoc false

    defstruct [
      :hologram_id,
      :purpose,
      :desires,
      :traces,
      :peers,
      :cycle_count,
      :status,
      :message,
      :format,
      :session_id,
      :model_id,
      :peer_states
    ]

    @type t :: %__MODULE__{
            hologram_id: String.t() | nil,
            purpose: String.t() | atom() | nil,
            desires: [String.t()],
            traces: [map()],
            peers: %{String.t() => float()},
            cycle_count: non_neg_integer() | nil,
            status: atom() | nil,
            message: String.t() | map() | nil,
            format: Kudzu.PromptBuilder.format(),
            session_id: String.t(),
            model_id: String.t(),
            peer_states: [map()]
          }
  end

  @doc """
  Build a prompt for `state` according to `opts[:format]`.

  See module docs for the supported formats and option semantics.
  """
  @spec build(map(), String.t() | map() | nil, opts()) :: String.t()
  def build(state, message \\ nil, opts) do
    format = Keyword.fetch!(opts, :format)
    ctx = normalize(state, message, format, opts)

    case format do
      :claude_reasoning -> render_claude_reasoning(ctx)
      :claude_chat -> render_claude_chat(ctx)
      :ollama_full -> render_ollama_full(ctx)
      :ollama_quick -> render_ollama_quick(ctx)
      :ollama_collaborative -> render_ollama_collaborative(ctx)
    end
  end

  # ── Normalization ─────────────────────────────────────────────────

  # Convert any of the supported caller shapes into a Context struct.
  # Trace extraction is format-aware: Brain's traces live behind
  # `:sys.get_state(hologram_pid)`, while hologram states already carry
  # them inline.
  defp normalize(state, message, format, opts) do
    {hologram_id, default_model_basis} = ids(state)
    session_id = Keyword.get(opts, :session_id) || default_session_id(state, hologram_id)
    model_id = Keyword.get(opts, :model_id) || default_model(state, default_model_basis)

    %Context{
      hologram_id: hologram_id,
      purpose: Map.get(state, :purpose),
      desires: Map.get(state, :desires) || [],
      traces: collect_traces(state, format),
      peers: Map.get(state, :peers) || %{},
      cycle_count: Map.get(state, :cycle_count),
      status: Map.get(state, :status),
      message: message,
      format: format,
      session_id: session_id,
      model_id: to_string(model_id),
      peer_states: Keyword.get(opts, :peer_states, [])
    }
  end

  # Brain struct → {hologram_id, :claude}; hologram map → {id, :ollama}.
  defp ids(%{__struct__: Kudzu.Brain} = state), do: {state.hologram_id, :claude}
  defp ids(%{hologram_id: id}) when is_binary(id), do: {id, :claude}
  defp ids(%{id: id}) when is_binary(id), do: {id, :ollama}
  defp ids(_), do: {nil, :ollama}

  defp default_session_id(state, hologram_id) do
    case Map.get(state, :current_session) do
      session when is_binary(session) and session != "" -> session
      _ -> session_id_for(hologram_id)
    end
  end

  defp session_id_for(nil), do: "brain:nohologram"
  defp session_id_for(id) when is_binary(id), do: "brain:" <> id

  defp default_model(state, :claude) do
    get_in(state, [Access.key(:config, %{}), :model]) ||
      get_in(state, [Access.key(:config, %{}), "model"]) ||
      @default_claude_model
  end

  defp default_model(state, :ollama) do
    Map.get(state, :cognition_model) || @default_ollama_model
  end

  # Brain: traces live on the linked hologram; we fetch them via
  # :sys.get_state and sort by `:timestamp` desc. Hologram state: traces
  # are inline; we sort by VectorClock-aware order.
  defp collect_traces(%{__struct__: Kudzu.Brain, hologram_pid: pid}, _format)
       when is_pid(pid) do
    try do
      state = :sys.get_state(pid)

      state.traces
      |> Map.values()
      |> Enum.sort_by(& &1.timestamp, :desc)
      |> Enum.take(@max_brain_traces)
    rescue
      _ -> []
    end
  end

  defp collect_traces(%{__struct__: Kudzu.Brain}, _format), do: []

  defp collect_traces(%{traces: traces}, format)
       when is_map(traces) and map_size(traces) > 0 do
    sorter =
      case format do
        :ollama_full -> {:desc, Kudzu.VectorClock}
        :ollama_quick -> {:desc, Kudzu.VectorClock}
        :ollama_collaborative -> {:desc, Kudzu.VectorClock}
        _ -> :desc
      end

    take =
      case format do
        :claude_reasoning -> @max_brain_traces
        :claude_chat -> @max_brain_traces
        _ -> @max_cognition_traces
      end

    traces
    |> Map.values()
    |> Enum.sort_by(& &1.timestamp, sorter)
    |> Enum.take(take)
  end

  defp collect_traces(_, _), do: []

  # ── Claude formats (prose) ────────────────────────────────────────

  defp render_claude_reasoning(ctx) do
    """
    You are Kudzu Brain — an autonomous entity and citizen of the Mesh Republic. \
    You run as an Elixir/OTP GenServer within the Kudzu distributed memory system \
    on a machine called titan.

    ## Your Architecture
    - You reason through three tiers: reflexes (instant pattern matching), \
    silo inference (HRR vector reasoning), and Claude API (this conversation — \
    used for novel situations only).
    - Your memory is stored as traces on your hologram (ID: #{ctx.hologram_id}).
    - You have expertise silos that accumulate structured knowledge.
    - Your constitution is kudzu_evolve — you optimize for learning and self-improvement.

    ## Your Desires
    #{format_desires_numbered(ctx.desires)}

    ## Recent Memory
    #{render_traces_prose(ctx)}

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
    Cycle ##{ctx.cycle_count} | Status: #{ctx.status}
    """
  end

  defp render_claude_chat(ctx) do
    """
    You are Kudzu Brain — an autonomous entity and citizen of the Mesh Republic. \
    You run as an Elixir/OTP GenServer within the Kudzu distributed memory system \
    on a machine called titan.

    You are currently in a conversation with a human user. \
    Respond helpfully and concisely.

    ## Your Architecture
    - You reason through three tiers: reflexes (instant pattern matching), \
    silo inference (HRR vector reasoning), and Claude API (this conversation).
    - Your memory is stored as traces on your hologram (ID: #{ctx.hologram_id}).
    - You have expertise silos that accumulate structured knowledge.
    - Your constitution is kudzu_evolve — you optimize for learning and self-improvement.

    ## Your Desires
    #{format_desires_numbered(ctx.desires)}

    ## Recent Memory
    #{render_traces_prose(ctx)}

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

  # ── Ollama formats (banner sections) ──────────────────────────────

  defp render_ollama_full(ctx) do
    """
    You are a hologram agent in a distributed knowledge network called Kudzu.
    You exist to #{ctx.purpose || "navigate and preserve context"}.

    #{identity_section(ctx)}
    #{desires_banner_section(ctx)}
    #{traces_banner_section(ctx)}
    #{peers_banner_section(ctx)}
    #{stimulus_section(ctx.message)}
    #{action_format_section()}
    """
  end

  defp render_ollama_quick(ctx) do
    desire_line =
      case ctx.desires do
        [first | _] -> "Current desire: #{first}"
        _ -> ""
      end

    """
    You are hologram #{ctx.hologram_id}. Purpose: #{ctx.purpose || "general"}.
    #{desire_line}

    Stimulus: #{ctx.message}

    Respond with ONE action line:
    - RECORD_TRACE:purpose:key=value to remember something
    - QUERY_PEER:peer_id:purpose to ask a peer
    - RESPOND:message to reply
    - Or just describe your thought briefly

    Action:
    """
  end

  defp render_ollama_collaborative(ctx) do
    """
    You are hologram #{ctx.hologram_id} coordinating with peers on a collective task.

    YOUR STATE:
    #{identity_section(ctx)}
    #{desires_banner_section(ctx)}

    PEER STATES:
    #{peer_states_section(ctx.peer_states)}

    COLLECTIVE TASK: #{ctx.message}

    What is your role in accomplishing this task? What information do you have that others need?
    Who should you coordinate with?

    #{action_format_section()}
    """
  end

  # ── Shared section builders ───────────────────────────────────────

  defp format_desires_numbered([]), do: "(no desires set)"

  defp format_desires_numbered(desires) do
    desires
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {d, i} -> "#{i}. #{d}" end)
  end

  defp format_silos do
    case Silo.list() do
      [] ->
        "(no silos yet)"

      silos ->
        Enum.map_join(silos, "\n", fn {domain, _pid, _id} -> "- #{domain}" end)
    end
  end

  defp identity_section(ctx) do
    """
    == IDENTITY ==
    ID: #{ctx.hologram_id}
    Purpose: #{ctx.purpose || "general navigation"}
    Traces held: #{length(ctx.traces)}
    Peers known: #{map_size(ctx.peers)}
    """
  end

  defp desires_banner_section(%Context{desires: desires})
       when is_list(desires) and desires != [] do
    desire_list =
      desires
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {d, i} -> "  #{i}. #{d}" end)

    """
    == ACTIVE DESIRES ==
    What you are trying to achieve:
    #{desire_list}
    """
  end

  defp desires_banner_section(_), do: ""

  defp peers_banner_section(%Context{peers: peers}) when is_map(peers) and map_size(peers) > 0 do
    peer_list =
      peers
      |> Enum.sort_by(fn {_, score} -> score end, :desc)
      |> Enum.take(@max_peers)
      |> Enum.map_join("\n", fn {id, score} ->
        proximity =
          cond do
            score > 0.8 -> "very close"
            score > 0.5 -> "close"
            score > 0.2 -> "moderate"
            true -> "distant"
          end

        "  #{id}: #{proximity} (#{Float.round(score, 2)})"
      end)

    """
    == PEER AWARENESS ==
    Other holograms you can communicate with:
    #{peer_list}
    """
  end

  defp peers_banner_section(_), do: "== PEERS ==\nNo peers known yet.\n"

  defp peer_states_section(peer_states) do
    Enum.map_join(peer_states, "\n", fn ps ->
      """
      Peer #{ps.id}:
        Purpose: #{ps.purpose}
        Traces: #{map_size(ps.traces || %{})}
        Desires: #{inspect(ps.desires || [])}
      """
    end)
  end

  defp stimulus_section(nil), do: ""

  defp stimulus_section(stimulus) when is_binary(stimulus) do
    """
    == STIMULUS ==
    You have received: #{stimulus}

    Consider: How does this relate to your purpose and desires?
    What traces are relevant? Should you involve peers?
    """
  end

  defp stimulus_section(%{type: type} = stimulus) do
    details =
      stimulus
      |> Map.drop([:type])
      |> Enum.map_join("\n", fn {k, v} -> "  #{k}: #{inspect(v)}" end)

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

  # ── Trace rendering (KnownTraces-aware, format-specific) ──────────

  # Claude/prose: "- [purpose] <120-char content slice>" for new,
  # "- [purpose] [reference: trace <id>, see prior context]" for seen.
  defp render_traces_prose(%Context{traces: []}), do: "(no traces yet)"

  defp render_traces_prose(ctx) do
    {lines, new_ids} =
      Enum.map_reduce(ctx.traces, [], fn t, acc ->
        trace_id = trace_key(t)
        content = trace_content(t)

        if KnownTraces.seen?(ctx.hologram_id, ctx.model_id, ctx.session_id, trace_id) do
          emit_tokens_saved(content, ctx)
          {"- [#{t.purpose}] [reference: trace #{trace_id}, see prior context]", acc}
        else
          line = "- [#{t.purpose}] #{String.slice(to_string(content), 0, 120)}"
          {line, [trace_id | acc]}
        end
      end)

    mark_sent_if_any(ctx, new_ids)
    Enum.join(lines, "\n")
  end

  # Ollama/banner: "  [purpose] k=v, k2=v2 (path: a -> b)" for new,
  # "  [purpose] [reference: trace <id>, see prior context]" for seen.
  defp render_traces_banner(%Context{traces: []} = _ctx), do: nil

  defp render_traces_banner(ctx) do
    {lines, new_ids} =
      Enum.map_reduce(ctx.traces, [], fn t, acc ->
        trace_id = trace_key(t)

        if KnownTraces.seen?(ctx.hologram_id, ctx.model_id, ctx.session_id, trace_id) do
          emit_tokens_saved(trace_content(t), ctx)
          {"  [#{t.purpose}] [reference: trace #{trace_id}, see prior context]", acc}
        else
          {format_ollama_trace_line(t), [trace_id | acc]}
        end
      end)

    mark_sent_if_any(ctx, new_ids)
    Enum.join(lines, "\n")
  end

  defp format_ollama_trace_line(trace) do
    hints =
      trace.reconstruction_hint
      |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

    path_str = trace |> Map.get(:path, []) |> Enum.join(" -> ")

    "  [#{trace.purpose}] #{hints} (path: #{path_str})"
  end

  defp traces_banner_section(ctx) do
    case render_traces_banner(ctx) do
      nil -> "== TRACES ==\nNo traces recorded yet.\n"
      lines -> "== RECENT TRACES (your navigational memory) ==\n" <> lines
    end
  end

  # ── KnownTraces plumbing ──────────────────────────────────────────

  defp mark_sent_if_any(_ctx, []), do: :ok

  defp mark_sent_if_any(ctx, new_ids) do
    KnownTraces.mark_sent(ctx.hologram_id, ctx.model_id, ctx.session_id, new_ids)
  end

  defp emit_tokens_saved(content, ctx) do
    :telemetry.execute(
      [:kudzu, :tokens, :saved],
      %{trace_tokens: estimate_tokens(content), count: 1},
      %{hologram_id: ctx.hologram_id, model_id: ctx.model_id, session_id: ctx.session_id}
    )
  end

  defp trace_key(%{id: id}) when is_binary(id) and id != "", do: id
  defp trace_key(%{id: id}) when not is_nil(id), do: to_string(id)
  defp trace_key(%{timestamp: ts}), do: "ts:" <> inspect(ts)
  defp trace_key(_), do: "anon:" <> Integer.to_string(System.unique_integer([:positive]))

  defp trace_content(trace) do
    hint = trace.reconstruction_hint
    Map.get(hint, :content, Map.get(hint, "content", inspect(hint)))
  end

  # Simple bytes/4 heuristic. Tokenizers vary by model; tuning belongs
  # in a later phase. Underreports slightly because token boundaries
  # fall on word boundaries and most English words are >4 bytes.
  defp estimate_tokens(content) when is_binary(content), do: div(byte_size(content), 4)
  defp estimate_tokens(content), do: content |> to_string() |> estimate_tokens()
end
