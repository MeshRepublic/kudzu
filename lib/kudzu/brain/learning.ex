defmodule Kudzu.Brain.Learning do
  @moduledoc """
  Directed learning-goal management for `Kudzu.Brain`.

  Owns curriculum generation, learning-goal lifecycle (start / progress /
  complete), and persistence of goals + researched-topic history through
  the Brain's hologram. Independent of `Kudzu.Brain.Chat` and
  `Kudzu.Brain.Reasoning`.
  """

  require Logger

  alias Kudzu.Brain
  alias Kudzu.Brain.ActivityIndicator
  alias Kudzu.Brain.CurriculumGenerator
  alias Kudzu.Brain.LearningGoal

  @doc """
  Render the current learning-goal lineup as a chat response tuple.

  Returns the standard `{response, tier, tool_calls, cost, state}` tuple
  used by the chat pipeline; the response describes the active, queued,
  and completed goals (or a "no goals" hint if none exist).
  """
  @spec report_learning_progress(Brain.t()) ::
          {String.t(), :reflex, [], float(), Brain.t()}
  def report_learning_progress(state) do
    case state.learning_goals do
      [] ->
        {"No active learning goals. Say 'Learn <topic>' to start one.", :reflex, [], 0.0, state}

      goals ->
        active = Enum.find(goals, &(&1.status == :active))
        queued = Enum.filter(goals, &(&1.status == :queued))
        completed = Enum.filter(goals, &(&1.status == :complete))

        parts = []

        parts =
          if active do
            [LearningGoal.progress_report(active) | parts]
          else
            ["No active learning goal." | parts]
          end

        parts =
          if queued != [] do
            queued_list = Enum.map_join(queued, "\n", &"  - #{&1.topic}")
            ["Queued:\n#{queued_list}" | parts]
          else
            parts
          end

        parts =
          if completed != [] do
            done_list =
              Enum.map_join(completed, "\n", &"  - #{&1.topic} (#{&1.completed_count} topics)")

            ["Completed goals:\n#{done_list}" | parts]
          else
            parts
          end

        response = parts |> Enum.reverse() |> Enum.join("\n\n")
        {response, :reflex, [], 0.0, state}
    end
  end

  @doc """
  Start (or queue) a new learning goal for a topic, generating its
  curriculum via `CurriculumGenerator`.

  Returns a chat-style response tuple. Duplicate topics that are already
  active or queued are reported as such and not re-queued; if a goal is
  already active the new one is queued behind it.
  """
  @spec start_learning_goal(Brain.t(), String.t()) ::
          {String.t(), :reflex, [], float(), Brain.t()}
  def start_learning_goal(state, topic) do
    normalized = String.downcase(topic)

    existing =
      Enum.find(state.learning_goals, fn g ->
        g.status in [:active, :queued] and String.downcase(g.topic) == normalized
      end)

    if existing do
      {"Already learning '#{topic}'. Say 'progress' to check status.", :reflex, [], 0.0, state}
    else
      Logger.info("[Brain] Generating curriculum for: #{topic}")

      ActivityIndicator.start_activity(
        :curriculum,
        "generating curriculum: #{String.slice(topic, 0, 40)}"
      )

      result = generate_curriculum(state, topic)
      ActivityIndicator.stop_activity(:curriculum)

      case result do
        {:ok, items, cost} ->
          goal = LearningGoal.new(topic, items)

          goal =
            if Enum.any?(state.learning_goals, &(&1.status == :active)) do
              %{goal | status: :queued}
            else
              goal
            end

          goals = state.learning_goals ++ [goal]
          state = %{state | learning_goals: goals}

          persist_learning_goals(state, goals)

          Brain.record_trace(state, :memory, %{
            source: "learning_goal_created",
            topic: topic,
            curriculum_size: length(items),
            status: goal.status,
            goal_id: goal.id
          })

          status_word = if goal.status == :active, do: "Started", else: "Queued"

          response =
            "#{status_word} learning '#{topic}' — #{length(items)} topics to cover.\n\n" <>
              "First 5 topics:\n" <>
              (items |> Enum.take(5) |> Enum.map_join("\n", &"  - #{&1}"))

          {response, :reflex, [], cost, state}

        {:error, reason} ->
          {"Failed to generate curriculum: #{inspect(reason)}", :reflex, [], 0.0, state}
      end
    end
  end

  @doc """
  Persist the goal list (and current researched-topic set) into the
  Brain's hologram as a `:session_context` trace.

  Best-effort: silently swallows errors so a hologram outage cannot
  block progress-tracking. Expects `state.hologram_pid` set; no-op if
  not.
  """
  @spec persist_learning_goals(Brain.t(), [struct()]) :: :ok | nil
  def persist_learning_goals(state, goals) do
    if state.hologram_pid do
      serialized =
        Enum.map(goals, fn g ->
          %{
            id: g.id,
            topic: g.topic,
            status: to_string(g.status),
            created_at: DateTime.to_iso8601(g.created_at),
            topics: Enum.map(g.topics, fn {t, s} -> %{topic: t, status: to_string(s)} end),
            current_index: g.current_index,
            completed_count: g.completed_count,
            failed_count: g.failed_count
          }
        end)

      try do
        Kudzu.Hologram.record_trace(state.hologram_pid, :session_context, %{
          source: "learning_goals_state",
          goals: serialized,
          researched_topics: MapSet.to_list(state.researched_topics)
        })
      rescue
        _ -> :ok
      end
    end
  end

  @doc """
  Restore the persisted learning-goal list from the Brain's hologram.

  Returns the most-recently-persisted goals, or `[]` if no
  `learning_goals_state` trace exists. Expects a live hologram pid.
  """
  @spec restore_learning_goals(pid()) :: [struct()]
  def restore_learning_goals(hologram_pid) do
    # Find the most recent learning_goals_state trace
    traces =
      try do
        Kudzu.Hologram.recall(hologram_pid, :session_context)
      catch
        _, _ -> []
      end

    goal_trace =
      traces
      |> Enum.filter(fn t ->
        hint = Map.get(t, :reconstruction_hint, %{})
        source = Map.get(hint, :source, Map.get(hint, "source", nil))
        source == "learning_goals_state"
      end)
      # most recent (traces are typically in chronological order)
      |> List.last()

    case goal_trace do
      %{reconstruction_hint: %{goals: serialized}} when is_list(serialized) ->
        deserialize_goals(serialized)

      %{reconstruction_hint: %{"goals" => serialized}} when is_list(serialized) ->
        deserialize_goals(serialized)

      _ ->
        []
    end
  end

  @doc """
  Restore the persisted set of curiosity questions that have already
  been researched.

  Returns the restored `MapSet`, or an empty one if no persisted state
  exists. Expects a live hologram pid.
  """
  @spec restore_researched_topics(pid()) :: MapSet.t(String.t())
  def restore_researched_topics(hologram_pid) do
    traces =
      try do
        Kudzu.Hologram.recall(hologram_pid, :session_context)
      catch
        _, _ -> []
      end

    goal_trace =
      traces
      |> Enum.filter(fn t ->
        hint = Map.get(t, :reconstruction_hint, %{})
        source = Map.get(hint, :source, Map.get(hint, "source", nil))
        source == "learning_goals_state"
      end)
      |> List.last()

    case goal_trace do
      %{reconstruction_hint: hint} ->
        topics_list = Map.get(hint, :researched_topics, Map.get(hint, "researched_topics", []))

        case topics_list do
          list when is_list(list) -> MapSet.new(list)
          _ -> MapSet.new()
        end

      _ ->
        MapSet.new()
    end
  end

  # ── Internals ───────────────────────────────────────────────────────

  defp generate_curriculum(_state, topic) do
    case CurriculumGenerator.generate(topic) do
      {:ok, items} -> {:ok, items, 0.0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deserialize_goals(serialized) do
    Enum.map(serialized, fn g ->
      topics =
        (g["topics"] || g[:topics] || [])
        |> Enum.map(fn t ->
          topic = t["topic"] || t[:topic] || ""

          status =
            case t["status"] || t[:status] do
              "complete" -> :complete
              "failed" -> :failed
              _ -> :pending
            end

          {topic, status}
        end)

      %LearningGoal{
        id: g["id"] || g[:id],
        topic: g["topic"] || g[:topic],
        status:
          case g["status"] || g[:status] do
            "active" -> :active
            "queued" -> :queued
            "complete" -> :complete
            _ -> :active
          end,
        created_at:
          case DateTime.from_iso8601(to_string(g["created_at"] || g[:created_at] || "")) do
            {:ok, dt, _} -> dt
            _ -> DateTime.utc_now()
          end,
        topics: topics,
        current_index: g["current_index"] || g[:current_index] || 0,
        completed_count: g["completed_count"] || g[:completed_count] || 0,
        failed_count: g["failed_count"] || g[:failed_count] || 0
      }
    end)
  end
end
