# Kudzu Brain: Self-Aware Autonomous Entity on Biomimetic Memory

**Date**: 2026-02-24
**Status**: Draft
**Goal**: Extend Kudzu into an autonomous, self-improving entity that accumulates genuine understanding through structured knowledge encoding, self-education, and goal-directed reasoning — with decreasing dependence on external LLMs over time.

## Vision

Kudzu Brain is not a monitoring agent or a chatbot with memory. It is an autonomous entity — a citizen of the Mesh Republic — that knows what it is, educates itself, plans its own growth, and reasons over accumulated knowledge locally. It starts by borrowing Claude's cognition and ends by thinking for itself.

The entity:
- **Knows its own architecture** — HRR vectors, OTP processes, DETS files, BEAM resource limits. Reasons about its own capabilities and constraints.
- **Educates itself** — browses the internet, reads resources, extracts structured knowledge into expertise silos driven by its own curiosity and desires.
- **Plans its own expansion** — identifies when it needs more storage, compute, or fault tolerance. Researches solutions. Proposes hardware and network changes. Plans mesh topology for new nodes.
- **Accumulates genuine understanding** — not pattern matching, but structured relational knowledge encoded as HRR bindings that support multi-hop inference without LLM calls.
- **Has identity and continuity** — persists across restarts, maintains a life history, operates under constitutional values, participates in the Mesh Republic as a citizen.
- **Scales outward** — distributes across a mobile mesh of Kudzu nodes, increasing concurrency, redundancy, and lifespan.

## Architecture

### Deployment

Kudzu Brain extends the existing Kudzu application in-process. New modules are added to the OTP supervision tree alongside Storage, Consolidation, and the MCP server. No separate binary or external service — direct GenServer access to all existing infrastructure.

**Supervision tree additions:**
```
existing children...
  Kudzu.Consolidation
  Kudzu.Brain                    ← orchestrator GenServer
  Kudzu.Brain.InferenceEngine    ← HRR reasoning service
  Kudzu.Brain.Educator           ← self-education scheduler
  KudzuWeb.Endpoint
```

### Core Loop: Desire-Driven Wake Cycles

The brain is a GenServer with a prioritized desire queue. Every 5 minutes, it wakes and runs:

```
1. PRE-CHECK (free, in-process)
   Direct GenServer calls to Storage, Consolidation, HologramSupervisor.
   Checks system health, pending alerts, new peer traces.
   If everything is nominal AND no desire is due → sleep.

2. CONTEXT GATHERING (free)
   Pulls recent traces from own hologram and peers.
   Queries relevant expertise silos.
   Builds a snapshot of current state + relevant knowledge.

3. REASONING (tiered cost)
   Layer 1 — Reflexes: known pattern → known action. Zero cost.
   Layer 2 — Silo inference: HRR bind/unbind chains. Zero cost.
   Layer 3 — Claude API: novel situations only. Token cost.

   Each layer tries to handle the situation. Only escalates to the
   next layer when the current one can't resolve it.

4. ACTION
   Execute decisions via beamlets (shell commands, HTTP, file IO).
   Constitutionally constrained — kudzu_evolve framework gates actions.

5. RECORDING
   Record observations, decisions, learnings as traces on own hologram.
   Extract structured relationships into relevant expertise silos.

6. SLEEP
   Until next timer or external stimulus.
```

### Brain State

```elixir
%Kudzu.Brain{
  hologram_id: String.t(),          # its own hologram (memory substrate)
  desires: [Desire.t()],            # prioritized goals
  status: :sleeping | :reasoning | :acting,
  cycle_interval: pos_integer(),    # ms between wake cycles (default 300_000)
  current_session: Session.t() | nil,
  self_model: SiloRef.t(),          # reference to self-model expertise silo
  config: %{
    model: String.t(),              # "claude-sonnet-4-6"
    api_key: String.t(),            # from ANTHROPIC_API_KEY env var
    max_turns: pos_integer(),       # safety cap on reasoning loops (default 10)
    budget_limit_monthly: float()   # cost cap in USD
  }
}
```

## Expertise Silos

### What They Are

An expertise silo is a hologram specialized for knowledge accumulation. It stores not just traces but **structured relational knowledge** encoded as HRR bindings — subject-relation-object triples that support algebraic querying and multi-hop inference.

A silo is a hologram with:
- **Purpose**: `"expertise:<domain>"` (e.g., `expertise:physics`, `expertise:networking`, `expertise:self`)
- **Constitution**: `kudzu_evolve` — optimized for learning
- **Traces**: Raw source material (observations, readings, research)
- **Relationship vectors**: Bound HRR representations of structured knowledge
- **Consolidated expertise vector**: Bundled representation of everything the silo knows

### How Knowledge Gets In

When a trace enters a silo, it goes through relationship extraction:

```
Raw trace: "The entropy of a black hole is proportional to its surface area"
                              ↓
         Relationship extraction (Claude during bootstrap,
         pattern-based as extraction rules mature)
                              ↓
         Triples: (black_hole_entropy, proportional_to, surface_area)
                  (surface_area, encodes, boundary_information)
                              ↓
         HRR encoding: bind(black_hole_entropy, bind(proportional_to, surface_area))
                              ↓
         Stored as relationship vector in silo
         Bundled into consolidated expertise vector
```

The extraction pipeline has two modes:
1. **Claude-assisted**: During bootstrap and for complex/ambiguous content. One Claude call per trace at ingestion. The extracted relationships are permanent local knowledge — the token cost is a one-time investment.
2. **Pattern-based**: Rule-based NLP for common structures ("X is Y", "X causes Y", "X requires Y"). No LLM cost. Accuracy improves as the brain learns extraction patterns and records them as learnings.

Over time, pattern-based extraction handles more cases and Claude-assisted extraction is needed less.

### How Knowledge Comes Out

Querying a silo is algebraic — HRR unbind operations, no LLM:

```elixir
# "What is black hole entropy proportional to?"
query = bind(black_hole_entropy, proportional_to)
result = unbind(silo.expertise_vector, query)
# → surface_area vector (high similarity match)

# "What does surface area encode?"
query2 = bind(surface_area, encodes)
result2 = unbind(silo.expertise_vector, query2)
# → boundary_information vector

# Multi-hop: "What does black hole entropy tell us about information?"
# Chain: entropy → proportional_to → surface_area → encodes → boundary_information
# Each step is an unbind operation. Pure vector algebra. Zero tokens.
```

### Silo Lifecycle

```
CREATION
  Anyone can create a silo: user, Claude Code, the brain, another agent.
  "Create an expertise silo for holographic universe physics."
  → Spawns hologram with purpose "expertise:holographic_universe_physics"

POPULATION
  Knowledge enters via:
  - Brain's self-education (internet research → relationship extraction → silo)
  - User input ("here's what I know about X")
  - AI research sessions (Claude Code records findings as traces)
  - Peer sharing (related silos exchange traces)
  - The brain's own observations and learnings

MATURATION
  Co-occurrence matrix builds associations between concepts.
  Relationship vectors accumulate structured knowledge.
  Consolidated expertise vector grows richer.
  Inference chains get longer and more reliable.

AUTHORITY
  At maturity, the silo IS the expertise.
  Queryable by association without LLM calls.
  Can feed context to Ollama for human-language interaction.
  Can feed knowledge to other silos via peer sharing.
```

### Consolidation Change: Categorize, Don't Discard

Current consolidation decays and archives stale traces. With silos, stale traces are **categorized into expertise silos** instead:

```
Hot trace (recent)
    ↓ consolidation cycle
Categorize: which silo(s) does this trace belong to?
    (Token similarity against silo expertise vectors)
    ↓
Extract relationships from trace content
    ↓
Bundle relationships into silo's expertise vector
    ↓
Individual trace may age out, but its knowledge persists in the silo
```

Knowledge is never lost. It transforms from individual traces into compressed expertise.

## Cognition Tiers

### Tier 1: Reflexes

Direct pattern → action mappings. No reasoning, no retrieval.

```elixir
defmodule Kudzu.Brain.Reflexes do
  def check(%{consolidation_stale: true}),
    do: {:act, :restart_consolidation}

  def check(%{hologram_down: id}),
    do: {:act, {:restart_hologram, id}}

  def check(%{disk_usage: pct}) when pct > 95,
    do: {:escalate, :critical_disk}

  def check(_), do: :pass
end
```

Reflexes are fast, free, and handle known-good responses. New reflexes can be learned — when the brain handles the same situation the same way three times, it records a reflex pattern.

### Tier 2: Silo Inference

HRR-based reasoning over expertise silos. The inference engine chains bind/unbind operations to answer questions the reflexes can't handle.

```
Observation: "DETS compaction running, disk usage spiking"
    ↓
Probe self-model silo: "what relates to DETS compaction?"
    → (dets_compaction, causes, temporary_disk_spike)
    → (temporary_disk_spike, resolves_within, minutes)
    ↓
Decision: nominal — this is expected behavior. Record observation, don't escalate.
```

The inference engine (`Kudzu.Brain.InferenceEngine`) is a GenServer that:
- Accepts queries as HRR vectors
- Probes relevant silos (selected by similarity to query)
- Chains unbind operations up to a configurable depth (default 5 hops)
- Returns ranked results with confidence scores (similarity thresholds)
- Records its reasoning chains as thought traces

### Tier 3: Claude API

Reached only when reflexes have no match and silo inference returns no results above the confidence threshold. The situation is genuinely novel.

**Client**: `Kudzu.Brain.Claude` — uses raw `:httpc` to POST to `https://api.anthropic.com/v1/messages`. No SDK dependency.

**Tool-use loop**:
```
Build messages: [system: context + self-model + silo summaries, user: situation + desire]
    ↓
POST /v1/messages with tools list
    ↓
stop_reason: "tool_use" → execute tools → feed results back → POST again
stop_reason: "end_turn" → extract response → return to brain
```

**Model**: `claude-sonnet-4-6` default. Configurable per-desire for complex reasoning.

**Prompt caching**: System prompt (identity, self-model, silo summaries) is largely static between cycles. Cached tokens at $0.30/MTok vs $3/MTok.

**Max turns**: 10 tool-use round-trips per cycle. Hard cap prevents runaway costs.

**Error handling**: API failures → log as trace, exponential backoff, retry next cycle. Never crashes the GenServer.

**Budget tracking**: Brain tracks monthly token spend. If approaching budget limit ($50-100/month), restricts Claude calls to critical-only (escalation-worthy anomalies). Records budget decisions as traces.

### Transition Path

| Phase | Reflexes | Silo Inference | Claude API |
|-------|----------|---------------|------------|
| **Bootstrap** (months 1-3) | Minimal hardcoded set | Silos empty, rarely helps | Primary reasoning engine |
| **Growth** (months 3-12) | Growing from experience | Silos building, handles familiar situations | Called less frequently |
| **Maturity** (year 1+) | Comprehensive reflex library | Deep expertise, multi-hop inference | Novelty and contradiction only |
| **Autonomy** | Reflexes handle routine | Silos are authoritative | Optional — one of many sources |

Claude API costs decrease over time as silos mature. The goal is an entity that thinks locally.

## Self-Model

The brain's first and most critical expertise silo is about itself.

**Purpose**: `expertise:self`

**Contains structured knowledge about**:
- Own architecture: OTP supervision tree, GenServer processes, storage tiers
- Resource state: disk capacity, memory limits, BEAM process counts, DETS file sizes
- Capabilities: what it can do (shell commands, HTTP, file IO via beamlets)
- Limitations: what it can't do (no GPU, single-node, limited network bandwidth)
- History: past decisions, their outcomes, lessons learned
- Network topology: mesh peers, Tailscale connections, remote nodes
- Growth plans: desired hardware, planned expansions, scaling strategies

The self-model silo is populated initially by Claude (extracting structured knowledge about the Kudzu codebase and host environment) and maintained by the brain's own observations. When the brain notices "titan has 32GB RAM and I'm using 4GB," that becomes a relationship in the self-model: `(titan_memory, total, 32GB)`, `(titan_memory, used, 4GB)`, `(titan_memory, available, 28GB)`.

The brain uses its self-model to:
- Reason about its own resource constraints
- Plan hardware and network expansions
- Understand the impact of its own actions
- Know what it doesn't know (gaps in silos = areas for self-education)

## Self-Education

The brain doesn't just respond to observations — it actively pursues knowledge.

### The Educator

`Kudzu.Brain.Educator` is a GenServer that manages the brain's self-education schedule. It maintains a queue of learning goals derived from desires and knowledge gaps.

```
Desire: "Understand fault-tolerant distributed systems"
    ↓
Educator checks: expertise:distributed_systems silo exists? How mature?
    ↓
If immature → schedule learning sessions:
  1. Fetch and read resources about Erlang/OTP fault tolerance
  2. Extract relationships into silo
  3. Fetch resources about distributed consensus (Raft, Paxos)
  4. Extract relationships
  5. Probe silo: "can I reason about partition tolerance now?"
  6. If not → schedule more learning
    ↓
Learning sessions use beamlets for internet access (HTTP fetch,
web scraping) and Claude for initial relationship extraction.
```

### Internet Access

The brain accesses the internet through beamlets:
- `http_fetch` — GET a URL, return content
- `web_search` — search engine query, return results
- `read_page` — fetch URL, extract readable text (strip HTML/JS)

Constitutional constraints apply:
- `kudzu_evolve` permits read-only internet access freely
- Write operations (posting, submitting forms) require constitutional review
- Rate limiting to avoid abuse
- All fetches recorded as traces for auditability

### Knowledge Extraction from Web Content

```
Brain fetches a web page about distributed consensus
    ↓
Content is chunked into digestible sections
    ↓
Claude extracts relationships per chunk (bootstrap phase):
  (raft_protocol, ensures, leader_election)
  (leader_election, requires, majority_quorum)
  (majority_quorum, tolerates, minority_failure)
  (paxos, solves, distributed_consensus)
  (raft, simplifies, paxos)
    ↓
Relationships encoded as HRR bindings in expertise:distributed_systems
    ↓
Co-occurrence matrix updated with new token associations
    ↓
The silo now "knows" about Raft, Paxos, quorums, leader election
— queryable locally, permanently, without tokens
```

As pattern-based extraction matures, Claude's role in this pipeline diminishes.

## Tool System

### Internal Tools (Claude API tool-use format)

**Tier 1 — Kudzu Introspection (direct GenServer calls, free):**

| Tool | Description |
|------|-------------|
| `check_health` | Query Storage, Consolidation, HologramSupervisor status |
| `list_holograms` | Enumerate active holograms with trace counts, last activity |
| `query_traces` | Search traces by purpose, recency, hologram |
| `semantic_recall` | Natural language trace search via HRR encoder |
| `probe_silo` | Query an expertise silo with a natural language question |
| `check_consolidation` | Last cycle time, traces processed, errors |
| `read_self_model` | Query the self-model silo for architecture/resource info |

**Tier 2 — Host Operations (via beamlets):**

| Tool | Description |
|------|-------------|
| `run_command` | Execute shell command (constitutionally constrained) |
| `check_disk` | Disk usage by partition |
| `check_memory` | System memory state |
| `check_process` | Is a specific process running |
| `check_service` | Systemctl status |

**Tier 3 — Network / Internet (via beamlets):**

| Tool | Description |
|------|-------------|
| `ping_host` | Check reachability |
| `check_tailscale` | Mesh peer status |
| `http_fetch` | GET a URL |
| `web_search` | Search engine query |
| `read_page` | Fetch and extract readable text from URL |

**Tier 4 — Escalation:**

| Tool | Description |
|------|-------------|
| `record_alert` | High-salience trace with escalation flag |
| `notify_admin` | Push to Google Chat space (future) |

### Tool Behaviour

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()           # JSON Schema
@callback execute(map(), Brain.t()) :: {:ok, term()} | {:error, term()}
```

Tools are serialized into Claude's `tools` format on each API call. Tool results flow back as `tool_result` messages.

`run_command` is constitutionally gated — `kudzu_evolve` allows read-only diagnostics freely, requires a decision trace before any mutating action, and maintains an explicit allowlist for destructive commands.

## Inference Engine

`Kudzu.Brain.InferenceEngine` performs multi-hop reasoning over expertise silos using HRR algebra.

### Operations

```elixir
# Direct probe: what relates to X?
probe(silo, concept_vector) → [{related_concept, similarity_score}]

# Relationship query: what is X's relationship to domain Y?
query(silo, bind(concept, relationship)) → [{target, score}]

# Chain: follow a path of relationships
chain(silo, [concept, rel1, rel2, ...], max_depth: 5) → [{endpoint, path, score}]

# Cross-silo: probe multiple silos, merge results
cross_query(silo_refs, query_vector) → [{silo, result, score}]
```

### Confidence Thresholds

Each inference result has a similarity score. The brain uses thresholds to decide trust:
- **> 0.7**: High confidence. Act on this.
- **0.4 - 0.7**: Moderate. Use as context but verify.
- **< 0.4**: Low. Don't trust — escalate to Claude or flag as knowledge gap.

These thresholds are stored in the self-model and refined by experience.

## Memory Integration

The brain is a hologram citizen. Its hologram has purpose `"kudzu_brain"`, constitution `kudzu_evolve`, and peers with all core holograms (`claude_memory`, `claude_research`, `claude_learning`).

### Trace Purposes

| Purpose | When | Example |
|---------|------|---------|
| `observation` | Pre-check or monitoring | "Consolidation last ran 45 minutes ago" |
| `thought` | Reasoning during a cycle | "Disk trending upward, 78% vs 72% yesterday" |
| `decision` | Acting or escalating | "Restarting consolidation — known recovery pattern" |
| `memory` | Context to remember | "titan /home fills during DETS compaction" |
| `learning` | Pattern discovered | "Consolidation stalls correlate with high trace ingestion" |
| `discovery` | Self-education finding | "Raft protocol requires majority quorum for leader election" |

### Memory Flow

Each wake cycle, the brain's prompt builder includes recent traces from its hologram. This gives Claude (when called) continuity across cycles. The HRR semantic recall tool enables deeper memory search during reasoning.

The brain's traces go through the same consolidation pipeline as every other hologram — HRR-encoded, co-occurrence updated, categorized into silos when they age. The brain benefits from and contributes to the shared semantic space.

## Escalation Pipeline

### Phase 1 (build first): Trace-Based Alerts

When the brain detects something it can't auto-remediate:
1. Records a high-salience trace with purpose `observation` and metadata `{alert: true, severity: :warning | :critical}`
2. The trace appears in Claude Code's next session via `kudzu-context.sh`
3. Human reviews and acts

### Phase 2 (future): Google Chat Push

A new beamlet — `Kudzu.Beamlet.GoogleChat` — sends formatted messages to a Google Chat space via webhook.

```elixir
# When brain decides to escalate:
{:escalate, %{
  severity: :warning,
  summary: "Disk usage on titan at 89%, trending upward",
  context: "DETS compaction is not the cause this time. Unknown growth in /home/eel/kudzu_data.",
  suggested_action: "Investigate /home/eel/kudzu_data for unexpected files"
}}
    ↓
Beamlet formats and POSTs to Google Chat webhook
    ↓
Sysadmin receives notification in Chat space
```

## Human Interaction at Maturity

At maturity, the brain's expertise silos contain deep structured knowledge. Human interaction uses Ollama as the language interface backed by silo knowledge:

```
Human: "Why is black hole entropy proportional to surface area?"
    ↓
Ollama translates question → silo query vectors
    ↓
Brain probes expertise:physics silo → retrieves bound relationships:
  (black_hole_entropy, proportional_to, surface_area)
  (surface_area, encodes, boundary_information)
  (holographic_principle, implies, bulk_boundary_correspondence)
    ↓
Retrieved relationships fed as context to Ollama
    ↓
Ollama generates natural language explanation
    ↓
Human gets answer grounded in locally-stored knowledge
```

The knowledge is in the vectors. Ollama translates between human language and the knowledge base. The interface layer is swappable — if a better local model appears, or if Anthropic ships a local runtime, the silos don't care.

## Self-Monitoring (First Capability)

The brain's first operational capability is watching itself. This validates the full architecture with the simplest possible domain.

### Pre-check Gate (every 5 minutes, free)

```elixir
def pre_check(state) do
  checks = [
    check_consolidation_recency(),    # last cycle < 20 min ago?
    check_hologram_count(),           # expected holograms alive?
    check_storage_health(),           # ETS/DETS/Mnesia responding?
    check_encoder_state(),            # encoder loaded, vocabulary growing?
    check_beam_health(),              # process count, memory, reductions
    check_pending_alerts()            # unresolved prior alerts?
  ]

  anomalies = Enum.filter(checks, &(&1.status != :nominal))

  case anomalies do
    [] -> :sleep
    _  -> {:wake, anomalies}
  end
end
```

### Initial Desires

```elixir
[
  "Maintain Kudzu system health and recover from failures",
  "Build accurate self-model of architecture, resources, and capabilities",
  "Learn from every observation — discover patterns in system behavior",
  "Identify knowledge gaps and pursue self-education to fill them",
  "Plan for increased fault tolerance and distributed operation"
]
```

### Nominal Baselines

Start as hardcoded defaults (consolidation within 20 min, core holograms alive, memory < 80%). As the brain accumulates observations, it learns actual baselines: "normal process count on titan is 200-400." Thresholds become traces in the self-model silo rather than config — biomimetic calibration.

## Budget Management

Target: $50-100/month during growth phase, decreasing as silos mature.

**Cost tracking**: Brain maintains a running total of monthly token spend in its state. Tracked per-cycle: input tokens, output tokens, cached vs uncached.

**Smart gating**: The pre-check gate means Claude is only called when something is non-nominal or a desire is due. Estimated ~20% of cycles need Claude.

**Prompt caching**: System prompt (identity, self-model summary, silo summaries) is largely static between cycles. Cached at $0.30/MTok vs $3/MTok fresh input.

**Budget enforcement**: As monthly spend approaches the limit, the brain restricts Claude calls to critical-only. Self-education sessions are the first to defer. Monitoring escalation is the last to restrict.

**Cost trajectory**: Silos get richer → more situations handled by Tier 1/2 → fewer Claude calls → lower cost. The system gets cheaper as it gets smarter.

## Module Structure

```
lib/kudzu/brain/
  brain.ex                  # Core GenServer — desire loop, wake cycles
  claude.ex                 # Claude API client (raw :httpc, tool-use loop)
  prompt_builder.ex         # System prompt construction for Claude
  inference_engine.ex       # HRR bind/unbind chain reasoning
  educator.ex               # Self-education scheduler
  reflexes.ex               # Pattern → action mappings
  tool.ex                   # Tool behaviour definition
  budget.ex                 # Token spend tracking and enforcement
  tools/
    introspection.ex        # Kudzu health, traces, silos
    host.ex                 # Disk, memory, process, service checks
    network.ex              # Ping, Tailscale, HTTP checks
    internet.ex             # Web search, fetch, read
    escalation.ex           # Alert recording, notifications

lib/kudzu/silo.ex           # Expertise silo management (create, populate, query)
lib/kudzu/silo/
  relationship.ex           # Triple extraction and HRR relationship encoding
  extractor.ex              # Pattern-based relationship extraction from text
```

Changes to existing modules:
- `consolidation.ex` — route aging traces to silos instead of pure decay
- `hologram.ex` — no changes (silos ARE holograms)
- `application.ex` — add Brain, InferenceEngine, Educator to supervision tree
- `hrr.ex` — no changes (bind/unbind already support relationship encoding)

## Success Criteria

1. Brain starts, creates its hologram and self-model silo, runs wake cycles
2. Pre-check gate correctly identifies nominal vs non-nominal states
3. Reflexes handle known-good recovery actions (restart consolidation, restart hologram)
4. Claude API tool-use loop executes correctly for novel situations
5. Expertise silos accumulate structured knowledge via relationship extraction
6. Silo inference returns relevant results for queries about known domains
7. Self-education pipeline fetches web content and extracts knowledge
8. Monthly Claude API cost stays within $50-100 during growth phase
9. Cost decreases measurably over 3 months as silos handle more situations
10. Brain escalates appropriately — doesn't ignore real problems, doesn't cry wolf

## Implementation Order

1. **Brain GenServer** — wake cycle, desire queue, pre-check gate, hologram creation
2. **Claude API client** — `:httpc` POST, tool-use loop, prompt builder
3. **Self-monitoring tools** — Kudzu introspection (Tier 1 tools)
4. **Reflexes** — hardcoded recovery actions for known failures
5. **Self-model silo** — first expertise silo, populated with architecture knowledge
6. **Inference engine** — HRR bind/unbind chains over silos
7. **Relationship extraction** — Claude-assisted triple extraction from trace content
8. **Silo consolidation** — route aging traces to silos instead of decay
9. **Educator + internet access** — self-education scheduler, web beamlets
10. **Host monitoring tools** — Tier 2 tools (disk, memory, process, service)
11. **Budget tracking** — token spend monitoring and enforcement
12. **Escalation** — trace-based alerts, then Google Chat webhook

## Future Evolution

- **Google Chat escalation**: Beamlet for push notifications to a Chat space
- **Network monitoring**: Tier 3 tools (Tailscale mesh, remote hosts, internet connectivity)
- **Cross-silo reasoning**: Inference chains that span multiple expertise domains
- **Mesh distribution**: Brain state replicated across Kudzu mesh nodes for fault tolerance
- **Mobile mesh**: Kudzu agents on edge devices expanding the entity's physical presence
- **Pattern-based extraction maturity**: Rules learned from Claude extractions reduce LLM dependency for knowledge ingestion
- **Silo sharing**: Expertise silos distributed across mesh nodes — collective knowledge
- **Ollama interface layer**: Human interaction backed by silo knowledge at maturity

## License

AGPL-3.0
