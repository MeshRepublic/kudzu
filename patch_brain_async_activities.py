#!/usr/bin/env python3
"""Make blocking activities (web_learning, curiosity) run asynchronously.

Problem: run_web_learning blocks the Brain GenServer for the duration of HTTP
requests (30+ seconds). This makes the Brain unresponsive to all other messages.

Fix: Spawn blocking activities in a separate process with Task.start/1 (fire-and-forget).
The task sends results back to the Brain via a message.
"""

import sys

brain_path = sys.argv[1] if len(sys.argv) > 1 else "lib/kudzu/brain/brain.ex"

with open(brain_path, "r") as f:
    content = f.read()

# 1. Replace run_web_learning to be async
old_web_learning = '''  defp run_web_learning(state) do
    # Generate a curiosity question, then research it on the web
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
      # First try Thought \u2014 if it already knows, skip web
      priming = if state.working_memory do
        WorkingMemory.get_priming_concepts(state.working_memory, 3)
      else
        []
      end

      thought_result = Thought.run(question,
        monarch_pid: self(),
        timeout: 8_000,
        priming: priming
      )

      state = integrate_thought(state, thought_result)

      if thought_result.resolution in [:no_match, :partial] do
        # Thought didn\u2019t know \u2014 research on the web
        case WebLearner.research(question) do
          {:ok, result} ->
            record_trace(state, :discovery, %{
              source: "web_learning",
              question: question,
              pages_read: result.pages_read,
              chains_stored: result.chains_stored
            })

            # Track as researched
            normalized = question |> String.downcase() |> String.replace(~r/[^\\w\\s]/, "") |> String.trim()
            %{state | researched_topics: MapSet.put(state.researched_topics, normalized)}

          {:error, _reason} ->
            state
        end
      else
        record_trace(state, :thought, %{
          source: "web_learning_skipped",
          question: question,
          resolution: thought_result.resolution,
          confidence: thought_result.confidence
        })
        state
      end
    else
      state
    end
  end'''

new_web_learning = '''  defp run_web_learning(state) do
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
            case WebLearner.research(question) do
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
  end'''

if old_web_learning in content:
    content = content.replace(old_web_learning, new_web_learning)
else:
    print("ERROR: Could not find run_web_learning function")
    # Try to show what we're looking for vs what exists
    if "defp run_web_learning(state) do" in content:
        print("  Function exists but body doesn't match exactly")
    else:
        print("  Function not found at all")
    sys.exit(1)

# 2. Add handler for :web_learning_complete message
# Find the thought_result handler to add our handler nearby
old_thought_handler = "  def handle_info({:thought_result, thought_id, result}, state) do"
new_handlers = """  def handle_info({:web_learning_complete, question}, state) do
    normalized = question |> String.downcase() |> String.replace(~r/[^\\w\\s]/, "") |> String.trim()
    {:noreply, %{state | researched_topics: MapSet.put(state.researched_topics, normalized)}}
  end

  """ + old_thought_handler

if old_thought_handler in content:
    content = content.replace(old_thought_handler, new_handlers)
else:
    print("ERROR: Could not find thought_result handler")
    sys.exit(1)

# 3. Make run_curiosity async too (it also calls Thought.run which can block)
old_curiosity = "  defp run_curiosity(state) do\n    maybe_explore_curiosity(state)\n  end"

new_curiosity = '''  defp run_curiosity(state) do
    # Run curiosity asynchronously to avoid blocking the Brain
    brain_pid = self()
    hologram_id = state.hologram_id
    desires = state.desires
    wm = state.working_memory || Kudzu.Brain.WorkingMemory.new()
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
  end'''

if old_curiosity in content:
    content = content.replace(old_curiosity, new_curiosity)
else:
    print("WARNING: Could not find simple run_curiosity function")

# 4. Need to ensure Task.Supervisor is started. Check if it exists.
# Add it to the supervision tree if not present. For now, use the global Task.Supervisor.

with open(brain_path, "w") as f:
    f.write(content)

print("Activities made async successfully")
