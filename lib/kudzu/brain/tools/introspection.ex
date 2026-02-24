defmodule Kudzu.Brain.Tools.Introspection do
  @moduledoc """
  Tier 1 introspection tools — let the Brain observe its own runtime.

  Provides four tools:

    * `check_health`        — system-wide health snapshot (holograms, consolidation, encoder, BEAM)
    * `list_holograms`      — enumerate active holograms with state summaries
    * `check_consolidation` — consolidation daemon stats and encoder vocabulary
    * `semantic_recall`     — query consolidated memory by natural language

  All external calls are wrapped in try/rescue so tools never crash —
  they return `{:error, message}` on failure instead.
  """

  alias Kudzu.Brain.Tool

  # ── CheckHealth ───────────────────────────────────────────────────

  defmodule CheckHealth do
    @moduledoc "System-wide health snapshot."
    @behaviour Tool

    @impl true
    def name, do: "check_health"

    @impl true
    def description do
      "Check overall Kudzu system health: holograms, consolidation daemon, " <>
        "HRR encoder, and BEAM VM metrics."
    end

    @impl true
    def parameters do
      %{type: "object", properties: %{}, required: []}
    end

    @impl true
    def execute(_params) do
      health = %{
        holograms: check_holograms(),
        consolidation: check_consolidation(),
        encoder: check_encoder(),
        beam: check_beam()
      }

      {:ok, health}
    rescue
      e -> {:error, "check_health crashed: #{Exception.message(e)}"}
    end

    defp check_holograms do
      count = Kudzu.Application.hologram_count()
      %{count: count, status: "ok"}
    rescue
      _ -> %{count: 0, status: "unreachable"}
    end

    defp check_consolidation do
      stats = Kudzu.Consolidation.stats()
      %{status: "ok", stats: stats}
    rescue
      _ -> %{status: "unreachable"}
    end

    defp check_encoder do
      state = Kudzu.Consolidation.get_encoder_state()

      %{
        status: "ok",
        vocabulary_size: map_size(state.token_counts),
        traces_processed: state.traces_processed
      }
    rescue
      _ -> %{status: "unreachable"}
    end

    defp check_beam do
      {uptime_ms, _} = :erlang.statistics(:wall_clock)

      %{
        process_count: :erlang.system_info(:process_count),
        memory_mb: div(:erlang.memory(:total), 1_048_576),
        uptime_seconds: div(uptime_ms, 1000)
      }
    end
  end

  # ── ListHolograms ─────────────────────────────────────────────────

  defmodule ListHolograms do
    @moduledoc "Enumerate active holograms with state summaries."
    @behaviour Tool

    @impl true
    def name, do: "list_holograms"

    @impl true
    def description do
      "List all active holograms with their ID, purpose, trace count, " <>
        "peer count, desires, and constitution."
    end

    @impl true
    def parameters do
      %{type: "object", properties: %{}, required: []}
    end

    @impl true
    def execute(_params) do
      pids = Kudzu.Application.list_holograms()

      holograms =
        pids
        |> Enum.map(&summarize_hologram/1)
        |> Enum.reject(&is_nil/1)

      {:ok, %{holograms: holograms, count: length(holograms)}}
    rescue
      e -> {:error, "list_holograms crashed: #{Exception.message(e)}"}
    end

    defp summarize_hologram(pid) do
      state = :sys.get_state(pid)

      %{
        id: state.id,
        purpose: state.purpose,
        trace_count: map_size(state.traces),
        peer_count: map_size(state.peers),
        desires_count: length(state.desires),
        constitution: state.constitution
      }
    rescue
      _ -> nil
    end
  end

  # ── CheckConsolidation ────────────────────────────────────────────

  defmodule CheckConsolidation do
    @moduledoc "Consolidation daemon statistics and encoder vocabulary."
    @behaviour Tool

    @impl true
    def name, do: "check_consolidation"

    @impl true
    def description do
      "Get detailed consolidation daemon stats: cycle counts, last run times, " <>
        "traces processed, vocabulary size, and blend strength."
    end

    @impl true
    def parameters do
      %{type: "object", properties: %{}, required: []}
    end

    @impl true
    def execute(_params) do
      stats = Kudzu.Consolidation.stats()
      encoder_state = Kudzu.Consolidation.get_encoder_state()

      result = %{
        stats: stats,
        encoder: %{
          vocabulary_size: map_size(encoder_state.token_counts),
          traces_processed: encoder_state.traces_processed,
          blend_strength: encoder_state.blend_strength
        }
      }

      {:ok, result}
    rescue
      e -> {:error, "check_consolidation crashed: #{Exception.message(e)}"}
    end
  end

  # ── SemanticRecall ────────────────────────────────────────────────

  defmodule SemanticRecall do
    @moduledoc "Query consolidated memory by natural language."
    @behaviour Tool

    @impl true
    def name, do: "semantic_recall"

    @impl true
    def description do
      "Search Kudzu's consolidated memory using a natural language query. " <>
        "Returns the top matching purposes ranked by semantic similarity."
    end

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Natural language search query"
          },
          limit: %{
            type: "integer",
            description: "Maximum number of results to return (default 5)"
          }
        },
        required: ["query"]
      }
    end

    @impl true
    def execute(params) do
      query = Map.fetch!(params, "query")
      limit = Map.get(params, "limit", 5)

      results =
        Kudzu.Consolidation.semantic_query(query, 0.0)
        |> Enum.take(limit)
        |> Enum.map(fn {purpose, similarity} ->
          %{purpose: purpose, similarity: Float.round(similarity, 4)}
        end)

      {:ok, %{query: query, results: results, count: length(results)}}
    rescue
      e -> {:error, "semantic_recall crashed: #{Exception.message(e)}"}
    end
  end

  # ── Module-Level Functions ────────────────────────────────────────

  @doc "Returns the list of all introspection tool modules."
  @spec all_tools() :: [module()]
  def all_tools do
    [CheckHealth, ListHolograms, CheckConsolidation, SemanticRecall]
  end

  @doc "Converts all introspection tools to Claude API format."
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
    case tool_by_name(name) do
      {:ok, module} -> module.execute(params)
      {:error, _} = err -> err
    end
  end

  defp tool_by_name(name) do
    case Enum.find(all_tools(), fn mod -> mod.name() == name end) do
      nil -> {:error, "unknown tool: #{name}"}
      module -> {:ok, module}
    end
  end
end
