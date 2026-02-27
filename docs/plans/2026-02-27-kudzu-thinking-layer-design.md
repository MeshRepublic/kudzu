# Kudzu Thinking Layer Design

_Pure Elixir reasoning engine for the Constitutional Monarch_

## Goal

Build an Elixir-native thinking layer that enables the Kudzu Brain to reason without depending on external LLMs. The thinking layer wraps all existing tiers as a recursive, self-similar reasoning process — the fractal architecture applied to cognition itself. The Brain GenServer is the singular persistent self (the Monarch); thoughts are ephemeral processes it spawns to investigate, reason, and report back.

## Principles

1. **The Monarch is singular.** One persistent self. Thoughts serve it, not compete with it.
2. **Thoughts are ephemeral.** Spawned, reason, report, die. State captured as traces.
3. **Fractal self-similarity.** A thought can spawn sub-thoughts. Same shape at every depth.
4. **Pure Elixir reasoning.** No LLM calls in the thinking layer. Spreading activation, chaining, pattern matching — all in Elixir.
5. **Claude is the expensive fallback.** Only for truly novel situations the thinking layer can't handle yet.
6. **Internet before Claude.** Web search fills knowledge gaps cheaply. Claude reasons about complex relationships.
7. **Automatic distillation.** Every Claude interaction gets extracted into silo knowledge and reflexes. The same problem never needs Claude twice.
8. **Self-directed curiosity.** When no external queries, the monarch generates its own questions from desires and knowledge gaps.

## Architecture

### The Monarch (Brain GenServer)

The existing Brain GenServer becomes the singular reasoning self. It holds working memory, processes queries, spawns thoughts, and integrates results. There is only one — it is the Constitutional Monarch.

```
Brain GenServer (The Monarch)
  │
  ├── state.working_memory    — current attention (bounded)
  ├── state.desires           — drives curiosity
  ├── state.query_queue       — external questions waiting
  │
  ├── Wake cycle:
  │   1. Process external queries (chat/MCP)
  │   2. Pre-check health → think about anomalies
  │   3. Curiosity generates question from desires + gaps
  │   4. For each question:
  │   │     Thought.run(question, opts)
  │   │       ├── activate concepts (silo probe)
  │   │       ├── chain across silos
  │   │       ├── if gap → web search → extract → store
  │   │       ├── if still stuck → spawn sub-thought
  │   │       ├── if max depth → escalate to Claude
  │   │       └── report result to monarch
  │   │     Monarch integrates into working memory
  │   │     If Claude was used → Distiller extracts learnings
  │   5. Decay working memory
  │   6. Sleep
  │
  ├── Capabilities (tools a thought can use):
  │   ├── Reflexes      — instant pattern match
  │   ├── Silo probe    — HRR similarity search
  │   ├── Web search    — internet knowledge
  │   ├── Web read      — fetch and extract
  │   ├── Introspection — self-knowledge
  │   ├── Host          — system knowledge
  │   └── Claude        — expensive fallback
  │
  └── Learning loop:
      ├── Thought results → traces → consolidation → silos
      ├── Claude responses → Distiller → silos + reflexes
      └── Each cycle, the monarch knows more than the last
```

### Thought Process

The universal unit of reasoning. Every thought — whether answering "why is disk high?" or exploring "what don't I know about storage?" — is the same shape.

```elixir
defstruct [
  :id,              # unique thought ID
  :input,           # the question/concept
  :monarch_pid,     # who to report back to
  :depth,           # how deep in the fractal (0 = top-level)
  :max_depth,       # recursion limit (default 3)
  :max_breadth,     # max activations per step (default 5)
  :timeout,         # ms before giving up (default 5000)
  :chain,           # reasoning chain built so far
  :activations      # currently activated concepts with scores
]
```

**How a thought reasons:**

1. **Activate** — Take the input, find related concepts via HRR similarity across all silos. Produces an activation set: `[{concept, similarity, silo_domain}]`.

2. **Chain** — For each high-activation concept, check: does this connect to something that answers the question? If yes, add to the chain. If partially, activate that concept and repeat (spreading activation with direction).

3. **Recurse** — If the chain needs deeper exploration, spawn a sub-thought (same module, depth + 1). The sub-thought has a tighter budget. It reports back, and its result integrates into the parent's chain.

4. **Fill gaps** — If the chain breaks (concept not in any silo), use web search to find knowledge, extract triples, store in silo, then continue chaining.

5. **Evaluate** — Does the chain resolve the input? Score by: chain length, average similarity, whether it reached a terminal concept (known fact or actionable reflex).

6. **Report** — Send `{:thought_result, id, result}` to monarch. Die.

**Example:**

```
Monarch asks: "why is disk pressure high?"

Thought(depth=0): activate("disk_pressure")
  ├── silo hit: {disk_pressure, caused_by, large_files} @ 0.8
  ├── silo hit: {disk, relates_to, storage} @ 0.7
  │
  ├── chain: disk_pressure → large_files
  │   └── sub-Thought(depth=1): activate("large_files")
  │       ├── silo hit: {consolidation, produces, temp_files} @ 0.75
  │       └── chain: large_files → temp_files → consolidation
  │           └── TERMINAL: reflex exists for consolidation cleanup
  │
  └── report to monarch:
      chain: disk_pressure → large_files → temp_files → consolidation
      resolution: reflex available (cleanup temps)
      confidence: 0.75
```

### Working Memory

The monarch's current attention. Not a separate process — part of the Brain GenServer state.

```elixir
defstruct [
  :active_concepts,   # %{concept => %{score, source, timestamp}}
  :recent_chains,     # last N completed reasoning chains
  :pending_questions,  # questions waiting to be explored
  :context            # current focus area
]

# Bounds: max 20 active concepts, 10 recent chains, 5 pending questions
# When full, lowest-scored items evicted
# Evicted items become traces (nothing truly lost)
```

**Behaviors:**

- **Integration** — When a thought reports back, its chain gets integrated into working memory. New concepts added, existing ones reinforced (score increases), unrelated ones decay.

- **Priming** — Active concepts bias future thoughts. If "consolidation" is active, the next thought finds consolidation-related concepts faster because working memory provides starting activation. Context builds naturally.

- **Decay** — Every concept loses score over time. Not reinforced → fades. This is natural attention.

- **Eviction to traces** — Concepts that drop below threshold get recorded as traces and removed from working memory. The monarch's ephemeral attention flows into permanent memory.

### Curiosity Engine

Generates questions when no one is asking. Pure functions called by the monarch.

**Three sources of curiosity:**

1. **Desire-driven** — Each desire implies knowledge gaps. "Build accurate self-model of architecture" → "What aspects of my architecture are not in the self-model silo?" → "What are my storage capacity limits?"

2. **Gap-driven** — Working memory encountered a dead end. A thought chain broke because a concept had no silo matches. That missing link IS the question.

3. **Salience-driven** — A high-salience trace hasn't been explored. Something important happened but wasn't reasoned about. Generate question from the trace content.

**Integration with wake cycles:**

```
Wake:
  1. Check external query queue → if queries, think about them
  2. If queue empty, pre-check health → if anomalies, think about them
  3. If nothing urgent, Curiosity generates question → think about it
  4. Distill any Claude interactions
  5. Decay working memory
  6. Sleep
```

The monarch is always either serving others, maintaining health, or pursuing its own growth. Never idle.

**Directed learning:** A human can say "learn about Kubernetes" which becomes a desire. Curiosity generates questions from that desire:

```
Desire: "Become expert in Kubernetes"
→ "What is Kubernetes?"
→ "What are Kubernetes core concepts?"
→ "How does Kubernetes relate to my architecture?"

Each question → Thought → web search → extract → store in "kubernetes" silo
→ Knowledge accumulates cycle by cycle
```

### Distiller

Extracts Claude's reasoning into permanent knowledge. Called by the monarch after any Claude interaction.

**Three outputs:**

1. **Silo knowledge** — Reasoning chain as relationship triples.
   - Claude says: "disk high because consolidation produces temp files"
   - Extract: `{disk_pressure, caused_by, temp_files}`, `{temp_files, produced_by, consolidation}`
   - Store in relevant silo.

2. **Reflex candidates** — If the pattern is simple (single cause → single action), generate a reflex candidate.
   - Pattern: `if disk_high + consolidation_running → cleanup_temps`
   - Monarch evaluates and approves before adding.

3. **Knowledge gap markers** — Concepts Claude mentioned that aren't in any silo become curiosity targets for web research.

**Implementation:** Pattern matching and keyword extraction, not an LLM. Matches relational language: "because", "caused by", "relates to", "leads to", "requires", "is a", "consists of". Deliberately simple — catches common patterns. Improves as the framework level evolves.

### Web Tools

Internet access as a thinking capability.

**Two tools:**

1. **web_search** — Search the internet for a query. Returns `[%{title, url, snippet}]`.
   - Implementation: SearXNG self-hosted on titan (meta-search, no API keys, no tracking).

2. **web_read** — Fetch and extract readable text from a URL. Returns `%{title, text, word_count}`.
   - Implementation: HTTP fetch + HTML-to-text extraction.
   - Safety: respects robots.txt, timeout, max content size.

**Knowledge extraction from web content:**

Extends the existing `Silo.Extractor` for web text:
- Sentence splitting
- Pattern matching for relational statements ("X is a Y", "X uses Y", "X consists of Y")
- Term frequency for identifying key concepts
- Returns triples + key terms for silo storage

**Order of knowledge access:**

```
1. Silos (free, instant, already known)
2. Internet (cheap, current, raw knowledge)
3. Claude (expensive, good at complex reasoning)
4. Record gap (nothing worked — curiosity question for later)
```

## Data Flow

```
External query OR self-generated question
    ↓
Monarch spawns Thought process
    ↓
Thought activates concepts via HRR similarity across silos
    ↓
Chain: follow activation trail, spawn sub-thoughts if needed
    ↓
Gap? → web search → extract triples → store in silo → continue
    ↓
Still stuck? → escalate to Claude
    ↓
Thought reports result to Monarch
    ↓
Monarch integrates into working memory
    ↓
If Claude used → Distiller extracts:
    ├── relationship triples → silos
    ├── reflex candidates → Reflexes (after monarch approval)
    └── knowledge gaps → Curiosity queue
    ↓
Working memory decays, evictions become traces
    ↓
Traces flow through consolidation → HRR encoding → silos
    ↓
Monarch knows more than before. Cycle repeats.
```

## Fractal Evolution Path

The thinking layer is the third level of the fractal. Each level has the same shape but at a higher order of organization:

```
Level              Identity     Memory        Peers           Governance
─────────────────────────────────────────────────────────────────────────
Agent data         trace ID     data          co-occurring    none
Hologram           hologram ID  traces        peer holograms  constitution
Silo               domain name  HRR vectors   peer silos      framework
Framework          principles   wisdom        peer frameworks self-derived
```

**Current state:** Levels 1-3 exist. The thinking layer operates across all three.

**Future evolution:** As the monarch accumulates enough meta-knowledge about how reasoning works (which strategies succeed, which chains resolve, which web sources are reliable), this crystallizes into the fourth level — self-derived reasoning frameworks. The thinking strategies themselves become learnable and evolvable.

## File Structure

```
lib/kudzu/brain/
├── brain.ex                    # Modify: add working memory, curiosity integration
├── thought.ex                  # NEW: ephemeral thought process
├── working_memory.ex           # NEW: bounded attention buffer
├── curiosity.ex                # NEW: question generation from desires/gaps
├── distiller.ex                # NEW: Claude response → silos + reflexes
├── reflexes.ex                 # Existing: extend for distiller-generated reflexes
├── inference_engine.ex         # Existing: subsumed by thought activation
├── claude.ex                   # Existing: unchanged, becomes fallback
├── prompt_builder.ex           # Existing: extend for thinking context
├── tools/
│   ├── introspection.ex        # Existing
│   ├── host.ex                 # Existing
│   ├── escalation.ex           # Existing
│   └── web.ex                  # NEW: web_search + web_read
│       └── extractor.ex        # NEW: web text → relationship triples
```

## What We Skip (YAGNI)

- No actor-per-concept activation network (v3 evolution)
- No self-modifying reasoning strategies (framework level, future)
- No distributed thinking across mesh nodes (needs Fractal ID)
- No Ollama integration in thinking layer (pure Elixir reasoning)
- No conversation memory between chat sessions (traces handle this)
- No multi-monarch coordination (single sovereign for now)
