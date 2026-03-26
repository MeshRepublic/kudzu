#!/usr/bin/env python3
"""Fix escalation order: recall -> silo -> web -> claude (not recall -> web -> silo -> claude)."""

import sys

brain_path = sys.argv[1] if len(sys.argv) > 1 else "lib/kudzu/brain/brain.ex"

with open(brain_path, "r") as f:
    lines = f.readlines()

# Find chat_escalate function boundaries
escalate_start = None
escalate_end = None
for i, line in enumerate(lines):
    if "defp chat_escalate(state, message) do" in line:
        escalate_start = i
    elif escalate_start and "defp format_recall_response" in line:
        escalate_end = i
        break

if escalate_start is None or escalate_end is None:
    print(f"ERROR: Could not find chat_escalate boundaries: start={escalate_start}, end={escalate_end}")
    sys.exit(1)

print(f"Replacing chat_escalate at lines {escalate_start+1}-{escalate_end}")

# Also find the comment block before the function (tier descriptions)
comment_start = escalate_start
for i in range(escalate_start - 1, max(escalate_start - 10, 0), -1):
    if lines[i].strip().startswith("#"):
        comment_start = i
    else:
        break

new_escalate = """\
  # Tier 1: Semantic Recall  \u2014 search stored traces (free)
  # Tier 2: Silo Inference   \u2014 Thought reasoning chain (free, instant)
  # Tier 3: Web Search       \u2014 research on the web (free, slow)
  # Tier 4: Claude API       \u2014 LLM reasoning (paid, last resort)
  #
  # Each tier enriches context for the next. Claude only fires if all
  # free tiers fail to produce a confident answer.

  defp chat_escalate(state, message) do
    # Accumulate context from each tier for potential Claude enrichment
    context = %{recall_results: [], web_findings: nil, thought_result: nil}

    # \u2500\u2500 Tier 1: Semantic Recall (free) \u2500\u2500
    Logger.info("[Brain] Escalation Tier 1: Semantic Recall")
    recall_results = try do
      Kudzu.Consolidation.semantic_query(message, 0.0)
    catch
      _, _ -> []
    end

    top_score = case recall_results do
      [{_purpose, score} | _] -> score
      _ -> 0.0
    end

    context = %{context | recall_results: recall_results}

    if top_score > 0.6 do
      # Strong recall match \u2014 synthesize response from stored knowledge
      response = format_recall_response(message, recall_results)

      record_trace(state, :thought, %{
        source: "chat_escalation",
        tier: "recall",
        top_score: top_score,
        matches: length(recall_results),
        message: String.slice(message, 0, 200)
      })

      Logger.info("[Brain] Escalation resolved at Tier 1 (recall, score=#{Float.round(top_score, 3)})")
      {response, :recall, [], 0.0, state}
    else
      # \u2500\u2500 Tier 2: Silo Inference (free, instant) \u2500\u2500
      Logger.info("[Brain] Escalation Tier 2: Silo Inference (Thought)")
      priming = if state.working_memory do
        WorkingMemory.get_priming_concepts(state.working_memory, 5)
      else
        []
      end

      thought_result = Thought.run(message,
        monarch_pid: self(),
        timeout: 10_000,
        priming: priming
      )

      state = integrate_thought(state, thought_result)
      context = %{context | thought_result: thought_result}

      if thought_result.resolution == :found and thought_result.confidence > 0.5 do
        response = format_thought_result(message, thought_result)

        record_trace(state, :thought, %{
          source: "chat_escalation",
          tier: "synthesis",
          resolution: thought_result.resolution,
          confidence: thought_result.confidence,
          chain_length: length(thought_result.chain),
          message: String.slice(message, 0, 200)
        })

        Logger.info("[Brain] Escalation resolved at Tier 2 (synthesis, confidence=#{Float.round(thought_result.confidence, 3)})")
        {response, :synthesis, [], 0.0, state}
      else
        # \u2500\u2500 Tier 3: Web Search (free, slow) \u2500\u2500
        Logger.info("[Brain] Escalation Tier 3: Web Search")
        web_result = try do
          WebLearner.research(message)
        catch
          _, _ -> {:error, :crashed}
        end

        context = case web_result do
          {:ok, findings} -> %{context | web_findings: findings}
          _ -> context
        end

        web_found = match?({:ok, %{chains_stored: n}} when n > 0, web_result)

        if web_found do
          {:ok, findings} = web_result
          response = format_web_response(message, findings)

          record_trace(state, :thought, %{
            source: "chat_escalation",
            tier: "web",
            pages_read: findings.pages_read,
            chains_stored: findings.chains_stored,
            message: String.slice(message, 0, 200)
          })

          Logger.info("[Brain] Escalation resolved at Tier 3 (web, #{findings.chains_stored} chains)")
          {response, :web, [], 0.0, state}
        else
          # \u2500\u2500 Tier 4: Claude API (paid, last resort) \u2500\u2500
          Logger.info("[Brain] Escalation Tier 4: Claude API (all free tiers exhausted)")
          enhanced_message = build_enriched_message(message, context)

          record_trace(state, :thought, %{
            source: "chat_escalation",
            tier: "claude",
            reason: "free_tiers_exhausted",
            recall_top_score: top_score,
            thought_resolution: thought_result.resolution,
            thought_confidence: thought_result.confidence,
            message: String.slice(message, 0, 200)
          })

          {response_text, tier, tool_calls, cost, new_state} =
            chat_with_claude(state, enhanced_message)

          # Distill knowledge from Claude's response
          new_state = if tier == 3 and response_text != "" do
            distill_claude_response(new_state, response_text)
          else
            new_state
          end

          {response_text, tier, tool_calls, cost, new_state}
        end
      end
    end
  end

"""

lines[comment_start:escalate_end] = [new_escalate]

# Now fix chat_escalate_stream similarly
# Re-find it since line numbers shifted
stream_start = None
stream_end = None
for i, line in enumerate(lines):
    if "defp chat_escalate_stream(state, message, stream_to) do" in line:
        stream_start = i
        break

if stream_start:
    # Find the end of this function (matching 2-space-indent end)
    depth = 0
    for i in range(stream_start, len(lines)):
        stripped = lines[i].strip()
        if lines[i].rstrip().endswith(" do") or stripped == "do":
            depth += 1
        if stripped == "end" and lines[i].startswith("  end"):
            stream_end = i
            break

    if stream_end:
        # Also find comment block before
        stream_comment_start = stream_start
        for i in range(stream_start - 1, max(stream_start - 5, 0), -1):
            if lines[i].strip().startswith("#") or lines[i].strip() == "":
                stream_comment_start = i
            else:
                break

        print(f"Replacing chat_escalate_stream at lines {stream_comment_start+1}-{stream_end+1}")

        new_stream = """\

  defp chat_escalate_stream(state, message, stream_to) do
    context = %{recall_results: [], web_findings: nil, thought_result: nil}

    # Tier 1: Semantic Recall
    send(stream_to, {:thinking, :recall, "Searching stored knowledge..."})
    recall_results = try do
      Kudzu.Consolidation.semantic_query(message, 0.0)
    catch
      _, _ -> []
    end

    top_score = case recall_results do
      [{_purpose, score} | _] -> score
      _ -> 0.0
    end

    context = %{context | recall_results: recall_results}

    if top_score > 0.6 do
      response = format_recall_response(message, recall_results)
      record_trace(state, :thought, %{source: "chat_escalation", tier: "recall", top_score: top_score})
      send(stream_to, {:chunk, response})
      {response, :recall, [], 0.0, state}
    else
      # Tier 2: Silo Inference
      send(stream_to, {:thinking, :synthesis, "Running silo inference..."})
      priming = if state.working_memory do
        WorkingMemory.get_priming_concepts(state.working_memory, 5)
      else
        []
      end

      thought_result = Thought.run(message, monarch_pid: self(), timeout: 10_000, priming: priming)
      state = integrate_thought(state, thought_result)
      context = %{context | thought_result: thought_result}

      if thought_result.resolution == :found and thought_result.confidence > 0.5 do
        response = format_thought_result(message, thought_result)
        record_trace(state, :thought, %{source: "chat_escalation", tier: "synthesis", confidence: thought_result.confidence})
        send(stream_to, {:chunk, response})
        {response, :synthesis, [], 0.0, state}
      else
        # Tier 3: Web Search
        send(stream_to, {:thinking, :web, "Searching the web..."})
        web_result = try do
          WebLearner.research(message)
        catch
          _, _ -> {:error, :crashed}
        end

        context = case web_result do
          {:ok, findings} -> %{context | web_findings: findings}
          _ -> context
        end

        web_found = match?({:ok, %{chains_stored: n}} when n > 0, web_result)

        if web_found do
          {:ok, findings} = web_result
          response = format_web_response(message, findings)
          record_trace(state, :thought, %{source: "chat_escalation", tier: "web", chains_stored: findings.chains_stored})
          send(stream_to, {:chunk, response})
          {response, :web, [], 0.0, state}
        else
          # Tier 4: Claude API
          send(stream_to, {:thinking, :claude, "Consulting Claude API..."})
          enhanced_message = build_enriched_message(message, context)
          record_trace(state, :thought, %{source: "chat_escalation", tier: "claude", reason: "free_tiers_exhausted"})
          chat_with_claude_stream(state, enhanced_message, stream_to)
        end
      end
    end
  end
"""

        lines[stream_comment_start:stream_end + 1] = [new_stream]
    else:
        print("WARNING: Could not find end of chat_escalate_stream")
else:
    print("WARNING: Could not find chat_escalate_stream")

with open(brain_path, "w") as f:
    f.writelines(lines)

print("Escalation order fixed: recall -> silo -> web -> claude")
