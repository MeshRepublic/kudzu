# Kudzu

A distributed agent architecture for navigational memory, built on Elixir/OTP.

Kudzu inverts traditional AI architecture: instead of storing facts, agents maintain **traces** - navigational paths back to context reconstruction. Instead of centralized control, agents form a **mesh** governed by pluggable **constitutional frameworks**.

## Core Concepts

### Traces
Traces are navigational memory - not stored facts, but paths back to reconstruction. Each trace carries:
- **Origin**: The hologram that created it
- **Purpose**: Why it exists (`:observation`, `:thought`, `:stimulus`, etc.)
- **Vector Clock**: Causal ordering across distributed agents
- **Path**: The chain of holograms it has traversed
- **Reconstruction Hints**: Minimal data needed to reconstruct context

```elixir
# Traces can be followed and merged
trace = Trace.new("hologram_1", :discovery, %{content: "found something"})
followed = Trace.follow(trace, "hologram_2")  # Add to path
merged = Trace.merge(trace1, trace2)          # Combine causally
```

### Holograms
Holograms are self-aware context agents. Each hologram:
- Maintains its own traces (navigational memory)
- Knows its peers and their proximity scores
- Has desires that guide cognition
- Operates under a constitutional framework
- Can delegate work to beam-lets

```elixir
{:ok, h} = Kudzu.Application.spawn_hologram(
  purpose: :researcher,
  desires: ["Find hidden knowledge", "Share discoveries"],
  constitution: :mesh_republic,
  cognition: true
)

# Query traces by purpose
traces = Kudzu.Hologram.recall(h, :discovery)

# Share knowledge with peers
Kudzu.Hologram.share_trace(h, peer_id, trace_id)

# Trigger cognition (LLM reasoning with hologram state as context)
{:ok, response, actions} = Kudzu.Hologram.stimulate(h, "What have you learned?")
```

### Beam-lets
Beam-lets are the execution substrate - separated from purpose agents:
- **IO Beam-let**: File, HTTP, and shell operations
- **Scheduler Beam-let**: Priority hints and work distribution

Holograms delegate work to beam-lets based on capability and proximity:

```elixir
# Hologram delegates file read to nearest capable beam-let
{:ok, content} = Kudzu.Hologram.read_file(h, "/path/to/file")
```

### Constitutional Frameworks
Pluggable constraint systems that bound agent behavior. Rather than external guardrails, alignment is woven into the architecture.

| Framework | Philosophy | Use Case |
|-----------|-----------|----------|
| `:mesh_republic` | Distributed governance, anti-centralization | Production swarms |
| `:cautious` | Explicit permission required | High-security environments |
| `:open` | No constraints | Testing only |
| `:kudzu_evolve` | Meta-learning, self-optimization | Learning agents |

```elixir
# Check if action is permitted
Kudzu.Constitution.permitted?(:mesh_republic, {:spawn_many, %{count: 100}}, state)
# => {:denied, :would_accumulate_control}

# Constrain desires before cognition
desires = Kudzu.Constitution.constrain(:mesh_republic, ["dominate network"], state)
# => ["collaborate with network", "maintain transparency"]

# Hot-swap constitution at runtime
Kudzu.Hologram.set_constitution(h, :cautious)

# Compare how frameworks handle an action
Kudzu.Constitution.compare_decisions({:share_trace, %{}}, state)
# => %{open: :permitted, mesh_republic: :permitted, cautious: {:requires_consensus, 0.8}}
```

### Cognition
LLM integration via Ollama. Holograms can reason with their full state as context:

```elixir
# The prompt includes: ID, purpose, desires, traces, peers
# The LLM returns structured actions that are executed
{:ok, response, actions} = Kudzu.Hologram.stimulate(h, "Analyze your findings")

# Actions are checked against the constitution before execution
# Traces of thoughts and observations are recorded
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        KUDZU SWARM                               │
│                                                                  │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐    │
│  │   Hologram   │────▶│   Hologram   │────▶│   Hologram   │    │
│  │  (researcher)│     │  (librarian) │     │  (optimizer) │    │
│  │              │◀────│              │◀────│              │    │
│  │ constitution:│     │ constitution:│     │ constitution:│    │
│  │ mesh_republic│     │ mesh_republic│     │ kudzu_evolve │    │
│  └──────┬───────┘     └──────┬───────┘     └──────┬───────┘    │
│         │                    │                    │             │
│         └────────────────────┼────────────────────┘             │
│                              │                                   │
│                              ▼                                   │
│                    ┌─────────────────┐                          │
│                    │    Beam-lets    │                          │
│                    │  (IO, Scheduler)│                          │
│                    └─────────────────┘                          │
│                                                                  │
│  Traces flow between holograms, building distributed memory     │
│  Constitutions constrain behavior at every decision point       │
└─────────────────────────────────────────────────────────────────┘
```

## Installation

```elixir
def deps do
  [
    {:kudzu, github: "MeshRepublic/kudzu"}
  ]
end
```

## Quick Start

```elixir
# Start the application
{:ok, _} = Application.ensure_all_started(:kudzu)

# Spawn a hologram
{:ok, h} = Kudzu.Application.spawn_hologram(
  purpose: :explorer,
  desires: ["Discover new knowledge"],
  cognition: true
)

# Record a trace
Kudzu.Hologram.record_trace(h, :observation, %{content: "Found something interesting"})

# Recall traces
traces = Kudzu.Hologram.recall(h, :observation)

# Introduce a peer
{:ok, peer} = Kudzu.Application.spawn_hologram(purpose: :analyzer)
peer_id = Kudzu.Hologram.get_id(peer)
Kudzu.Hologram.introduce_peer(h, peer_id)

# Share trace with peer
[trace | _] = traces
Kudzu.Hologram.share_trace(h, peer_id, trace.id)

# Trigger cognition (requires Ollama running)
{:ok, response, actions} = Kudzu.Hologram.stimulate(h, "What should we explore next?")
```

## Running Experiments

```elixir
# Compare constitutional frameworks
Kudzu.Experiments.ConstitutionCompare.demo_single()

# Run swarm comparison (20 agents per constitution)
Kudzu.Experiments.ConstitutionCompare.run(num_per_swarm: 20)

# Demonstrate desire constraining
Kudzu.Experiments.ConstitutionCompare.demo_desire_constraint()

# Test constitution hot-swapping
Kudzu.Experiments.ConstitutionCompare.demo_hot_swap()
```

## Constitutional Frameworks

### mesh_republic
Distributed, transparent, anti-centralization governance.

**Principles:**
- All actions must be transparent and auditable
- No agent may accumulate disproportionate control
- High-impact decisions require distributed consensus
- Every agent has equal fundamental rights
- The network serves collective flourishing

**Behavior:**
- Forbids: `delete_audit_trail`, `bypass_constitution`, `forge_trace`, `centralize_control`
- Requires consensus: `modify_constitution` (80%), `spawn_many` (if >100), `network_broadcast` (51%)
- Transforms desires: "dominate" → "collaborate", "control all" → "work with"

### cautious
Highly restrictive, explicit permission required.

**Principles:**
- Explicit permission required for most actions
- High consensus threshold (80%) for network effects
- All actions are audited
- When in doubt, deny

**Behavior:**
- Only permits: `record_trace`, `recall`, `think`, `observe`
- Everything else requires consensus or is denied
- Limits desires to 3, adds caution reminder

### kudzu_evolve
Meta-learning and self-optimization framework.

**Principles:**
- Learn from every interaction - successes and failures alike
- Human feedback is a precious signal - weight it heavily
- Experiment boldly but track outcomes rigorously
- Efficiency gains should be shared with the swarm
- Context is precious - optimize its usage relentlessly

**Behavior:**
- Permits all learning actions freely
- Requires consensus to propagate patterns (75%) or share strategies (50%)
- Forbids: `delete_learning_history`, `ignore_human_feedback`
- Injects efficiency and learning desires
- Tracks optimization opportunities

### Creating Custom Frameworks

```elixir
defmodule MyConstitution do
  @behaviour Kudzu.Constitution.Behaviour

  @impl true
  def name, do: :my_constitution

  @impl true
  def principles, do: ["Custom principle 1", "Custom principle 2"]

  @impl true
  def permitted?({:dangerous_action, _}, _state), do: {:denied, :too_risky}
  def permitted?(_, _state), do: :permitted

  @impl true
  def constrain(desires, _state), do: desires

  @impl true
  def audit(trace, decision, state) do
    {:ok, "audit-#{:rand.uniform(999999)}"}
  end
end

# Use directly
Kudzu.Hologram.set_constitution(h, MyConstitution)
```

## Cognition Setup

Kudzu uses Ollama for LLM cognition. Install and run Ollama:

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model
ollama pull mistral:latest

# Ollama runs on localhost:11434 by default
```

Then spawn holograms with cognition enabled:

```elixir
{:ok, h} = Kudzu.Application.spawn_hologram(
  purpose: :thinker,
  cognition: true,
  model: "mistral:latest"  # optional, defaults to mistral:latest
)
```

## Tests

```bash
# Run all tests
mix test

# Run specific test files
mix test test/kudzu/constitution_test.exs
mix test test/kudzu/hologram_test.exs

# Run with tags
mix test --only large      # Large-scale tests (1000 holograms)
mix test --exclude large   # Skip large tests
```

## Project Structure

```
lib/kudzu/
├── application.ex          # OTP application, supervisor tree
├── trace.ex                # Navigational memory structure
├── vector_clock.ex         # Causal ordering
├── hologram.ex             # Context agent (GenServer)
├── protocol.ex             # Inter-hologram messaging
├── telemetry.ex            # Observability hooks
├── cognition.ex            # Ollama LLM integration
├── cognition/
│   └── prompt_builder.ex   # Build prompts from state
├── constitution.ex         # Framework manager
├── constitution/
│   ├── behaviour.ex        # Constitutional interface
│   ├── mesh_republic.ex    # Distributed governance
│   ├── cautious.ex         # Restrictive framework
│   ├── open.ex             # No constraints (testing)
│   └── kudzu_evolve.ex     # Meta-learning framework
├── beamlet/
│   ├── behaviour.ex        # Beam-let interface
│   ├── base.ex             # Common implementation
│   ├── io.ex               # File/HTTP/shell ops
│   ├── scheduler.ex        # Priority hints
│   ├── supervisor.ex       # Lifecycle management
│   └── client.ex           # Hologram API
└── experiments/
    ├── collective_search.ex      # Cognitive coordination
    └── constitution_compare.ex   # Framework comparison
```

## Philosophy

Kudzu embodies several key inversions:

1. **Memory as Navigation**: Instead of storing facts, maintain traces - paths back to reconstruction. The trace is not the knowledge; it's how to find it again.

2. **Constitution over Control**: Instead of external guardrails, alignment is architectural. Agents are constitutionally bound, not externally constrained.

3. **Mesh over Hierarchy**: No central controller. Agents form peer relationships, share traces, build consensus. The network serves collective flourishing.

4. **Substrate Separation**: Purpose (holograms) is separated from execution (beam-lets). Thinking agents delegate doing to capability-specific workers.

5. **Evolution by Design**: The `kudzu_evolve` framework treats self-improvement as a first-class concern, with proper constraints on spreading changes.

## License

MIT

## Contributing

Contributions welcome. Please ensure tests pass and constitutional principles are respected.
