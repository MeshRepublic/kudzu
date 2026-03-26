#!/usr/bin/env python3
"""Make blocking activities async using line-based replacement."""

import sys

brain_path = sys.argv[1] if len(sys.argv) > 1 else "lib/kudzu/brain/brain.ex"

with open(brain_path, "r") as f:
    lines = f.readlines()

# Find function boundaries
def find_function(lines, func_name, start_from=0):
    """Find start and end line indices of a defp function."""
    start = None
    for i in range(start_from, len(lines)):
        if func_name in lines[i]:
            start = i
            break
    if start is None:
        return None, None

    # Find the matching end (2-space indent)
    depth = 0
    for i in range(start, len(lines)):
        line = lines[i]
        stripped = line.strip()
        if stripped in ('do', '') or line.rstrip().endswith(' do'):
            depth += 1
        # Count do/end pairs to find the right closing end
        if stripped == 'end' and line.startswith('  end'):
            return start, i
    return start, None

# 1. Replace run_curiosity (lines 1255-1257)
cur_start, cur_end = find_function(lines, "defp run_curiosity(state)")
print(f"run_curiosity: lines {cur_start+1}-{cur_end+1}")

new_curiosity = """\
  defp run_curiosity(state) do
    # Run curiosity asynchronously to avoid blocking the Brain
    brain_pid = self()
    hologram_id = state.hologram_id
    desires = state.desires
    wm = state.working_memory || WorkingMemory.new()
    silo_domains = get_silo_domains_for_activity()

    Task.start(fn ->
      try do
        questions = Curiosity.generate(desires, wm, silo_domains)

        if question = List.first(questions) do
          thought_result = Thought.run(question,
            monarch_pid: brain_pid,
            timeout: 8_000,
            priming: []
          )

          if hologram_id do
            Kudzu.Hologram.record_trace(hologram_id, :thought, %{
              source: "curiosity",
              question: question,
              resolution: thought_result.resolution,
              confidence: thought_result.confidence
            })
          end
        end
      catch
        kind, reason ->
          Logger.warning("[Brain] Async curiosity crashed: \#{inspect(kind)}: \#{inspect(reason)}")
      end
    end)

    state
  end
"""

# 2. Replace run_web_learning (lines 1259-1321)
web_start, web_end = find_function(lines, "defp run_web_learning(state)")
print(f"run_web_learning: lines {web_start+1}-{web_end+1}")

new_web_learning = """\
  defp run_web_learning(state) do
    # Generate a curiosity question, then research it on the web
    # Run asynchronously so we don't block the Brain GenServer
    silo_domains = get_silo_domains_for_activity()
    wm = state.working_memory || WorkingMemory.new()
    questions = Curiosity.generate(state.desires, wm, silo_domains)

    # Filter out already-researched topics
    question =
      questions
      |> Enum.reject(fn q ->
        normalized = q |> String.downcase() |> String.replace(~r/[^\\w\\s]/, "") |> String.trim()
        MapSet.member?(state.researched_topics, normalized)
      end)
      |> List.first()

    if question do
      brain_pid = self()
      hologram_id = state.hologram_id

      # Fire-and-forget: run web learning in a separate unlinked process
      Task.start(fn ->
        try do
          # First try Thought
          thought_result = Thought.run(question,
            monarch_pid: brain_pid,
            timeout: 8_000,
            priming: []
          )

          if thought_result.resolution in [:no_match, :partial] do
            # Thought didn't know \u2014 research on the web
            case Kudzu.Brain.WebLearner.research(question) do
              {:ok, result} ->
                # Record trace directly on the hologram
                if hologram_id do
                  Kudzu.Hologram.record_trace(hologram_id, :discovery, %{
                    source: "web_learning",
                    question: question,
                    pages_read: result.pages_read,
                    chains_stored: result.chains_stored
                  })
                end

                # Notify brain to track as researched
                send(brain_pid, {:web_learning_complete, question})

              {:error, reason} ->
                Logger.warning("[Brain] Web learning failed: \#{inspect(reason)}")
            end
          else
            Logger.debug("[Brain] Web learning skipped \u2014 Thought resolved: \#{question}")
          end
        catch
          kind, reason ->
            Logger.warning("[Brain] Async web learning crashed: \#{inspect(kind)}: \#{inspect(reason)}")
        end
      end)

      state
    else
      state
    end
  end
"""

# 3. Add :web_learning_complete handler before :thought_result handler
thought_line = None
for i, line in enumerate(lines):
    if "def handle_info({:thought_result, thought_id, result}, state) do" in line:
        thought_line = i
        break

print(f"thought_result handler: line {thought_line+1}")

new_handler = """\
  def handle_info({:web_learning_complete, question}, state) do
    normalized = question |> String.downcase() |> String.replace(~r/[^\\w\\s]/, "") |> String.trim()
    {:noreply, %{state | researched_topics: MapSet.put(state.researched_topics, normalized)}}
  end

"""

# Apply replacements from bottom to top so line numbers don't shift
# First: replace run_web_learning
lines[web_start:web_end+1] = [new_web_learning]

# Second: replace run_curiosity (above web_learning, so indices still valid)
lines[cur_start:cur_end+1] = [new_curiosity]

# Third: insert handler before thought_result (need to re-find since lines shifted)
for i, line in enumerate(lines):
    if "def handle_info({:thought_result, thought_id, result}, state) do" in line:
        lines.insert(i, new_handler)
        break

with open(brain_path, "w") as f:
    f.writelines(lines)

print("Activities made async successfully")
