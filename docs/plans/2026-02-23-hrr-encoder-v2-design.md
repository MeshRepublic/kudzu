# HRR Encoder V2: Token-Seeded Bundling with Co-occurrence Learning

_Design doc for evolving Kudzu's self-contained semantic memory_

## Problem

The current HRR encoder (`Kudzu.HRR.Encoder.encode_content/2`) hashes the entire stringified reconstruction hint into a single deterministic vector:

```elixir
defp encode_content(hint, dim) when is_map(hint) do
    content_str = inspect(hint)
    HRR.seeded_vector(content_str, dim)
end
```

This means two traces about the same topic but with different wording produce completely unrelated vectors. "HologramRegistry wasn't in the supervision tree" and "OTP application child spec missing" have zero similarity despite being about the same concept. The HRR infrastructure (bind, unbind, bundle, probe, consolidation, salience) is fully built but can't deliver associative retrieval because the content encoding is a hash, not an embedding.

## Design Principles

1. **Self-contained**: No external models, no API calls. The encoder runs entirely in Elixir using Kudzu's existing HRR math.
2. **Evolutionary**: The encoding quality improves over time as Kudzu processes more traces. Day one works; day 100 works better.
3. **Deterministic base layer**: Token-to-vector mapping is seeded and reproducible. Given the same token, you always get the same base vector.
4. **Learned overlay**: Co-occurrence relationships between tokens are learned from trace data and influence encoding. This layer starts empty and grows.

## Architecture

### Encoding Pipeline (per trace)

```
Input: trace.reconstruction_hint (map with content, project, event, etc.)

1. EXTRACT  — Pull text from hint fields, concatenate with field labels
2. TOKENIZE — Lowercase, split on whitespace/punctuation, drop stopwords
3. BIGRAMS  — Extract adjacent pairs as compound tokens ("supervision_tree")
4. VECTORIZE — For each token:
   a. Base vector = HRR.seeded_vector("token_v2_#{token}", dim)
   b. Look up top-K co-occurrence neighbors (K=5)
   c. Blend: token_vec = normalize(base_vec + blend_strength * sum(neighbor_vecs * co_occurrence_weight))
5. BIND     — Bind token vectors with field-role vectors (content, project, event)
6. BUNDLE   — Bundle all bound vectors into final content vector
```

Step 4c is the evolutionary part. When co-occurrence data is empty (fresh system), `sum(neighbor_vecs * weight)` is zero and encoding reduces to pure token-seeded bundling. As data accumulates, tokens that frequently co-occur influence each other's vectors, creating emergent semantic relationships.

### Learning Pipeline (during consolidation)

Runs as a step in the existing consolidation daemon cycles:

**Light cycle (every 10 minutes):**
```
For each newly consolidated trace:
  tokens = tokenize(trace)
  For each pair (token_a, token_b) in tokens:
    co_occurrence[token_a][token_b] += 1
    co_occurrence[token_b][token_a] += 1
```

**Deep cycle (every 6 hours):**
```
1. Apply decay: co_occurrence *= 0.98 (prevents stale associations from dominating)
2. Prune entries below threshold (< 1.0) to keep matrix sparse
3. Rebuild vocabulary cache of top-N tokens by total co-occurrence
4. Persist co-occurrence matrix and vocabulary to DETS
```

### Data Structures

```elixir
defmodule Kudzu.HRR.EncoderState do
  @type t :: %__MODULE__{
    codebook: map(),           # existing role/purpose codebook
    vocabulary: %{String.t() => HRR.vector()},  # cached token vectors
    co_occurrence: %{String.t() => %{String.t() => float()}},  # sparse matrix
    token_counts: %{String.t() => non_neg_integer()},  # total token frequency
    blend_strength: float(),   # 0.0 = pure token seeding, 1.0 = full co-occurrence
    dim: pos_integer()
  }
end
```

The co-occurrence matrix is sparse — only stores non-zero pairs. For 1000 unique tokens with average 10 neighbors each, that's ~10K entries. Fits easily in memory and DETS.

### Persistence

- **EncoderState** persisted to DETS at `/home/eel/kudzu_data/dets/encoder_state.dets`
- Saved during deep consolidation cycle and on graceful shutdown
- Loaded on startup by the Consolidation daemon
- If missing or corrupt, encoder starts fresh (pure token seeding) — no data loss, just cold start

### Tokenization

**Process:**
1. Extract string values from reconstruction_hint map (content, summary, event, key_events)
2. Lowercase
3. Replace punctuation with spaces (preserve underscores and hyphens within words)
4. Split on whitespace
5. Drop stopwords
6. Drop tokens shorter than 2 characters
7. Extract bigrams from adjacent non-stopword tokens (joined with underscore)

**Stopwords** — minimal, domain-aware list:
```
the, a, an, is, was, were, are, be, been, being,
have, has, had, do, does, did, will, would, could,
should, may, might, can, shall, of, to, in, for,
on, with, at, by, from, that, this, it, its, and,
or, but, not, no, if, then, than, so, as, into
```

Technical terms are never stopwords regardless of frequency. The list is intentionally short — over-filtering loses signal.

**Bigrams:**
```
"hologram registry supervision tree"
→ unigrams: [hologram, registry, supervision, tree]
→ bigrams:  [hologram_registry, registry_supervision, supervision_tree]
→ all tokens: [hologram, registry, supervision, tree,
               hologram_registry, registry_supervision, supervision_tree]
```

Bigrams capture phrases that have meaning beyond their parts. "supervision_tree" is a concept; "supervision" and "tree" separately are less specific.

### Co-occurrence Blending

When encoding a token, look up its top-K co-occurrence neighbors and blend their base vectors in:

```elixir
def contextual_vector(token, encoder_state) do
  base = get_or_create_base_vector(token, encoder_state)

  neighbors = get_top_neighbors(token, encoder_state.co_occurrence, k: 5)

  if neighbors == [] do
    base  # no co-occurrence data yet, pure base vector
  else
    # Weight neighbor vectors by normalized co-occurrence strength
    total_weight = Enum.sum(Enum.map(neighbors, fn {_t, w} -> w end))
    neighbor_blend = neighbors
      |> Enum.map(fn {neighbor_token, weight} ->
        nvec = get_or_create_base_vector(neighbor_token, encoder_state)
        HRR.scale(nvec, weight / total_weight)
      end)
      |> Enum.reduce(HRR.zero_vector(encoder_state.dim), &HRR.add/2)

    blended = HRR.add(base, HRR.scale(neighbor_blend, encoder_state.blend_strength))
    HRR.normalize(blended)
  end
end
```

`blend_strength` defaults to 0.3 — strong enough to create association but not so strong that tokens lose their identity. This can be tuned.

### Multi-field Encoding

Different hint fields carry different types of information. Each gets its own role vector for binding:

```
content field  → bind(content_role, token_bundle)   # main semantic content
project field  → bind(project_role, token_bundle)   # project context
event field    → bind(event_role, token_bundle)      # event type
```

All bound field vectors are bundled into the final content vector. This preserves the structural distinction — a probe for "project:kudzu" differs from "content:kudzu".

## Integration Points

### Consolidation Daemon (`Kudzu.Consolidation`)

Current `process_hot_traces/2` calls `Encoder.consolidate/2`. Update to:

1. Pass encoder state (with co-occurrence data) instead of bare codebook
2. After encoding traces, update co-occurrence matrix with new token pairs
3. On deep consolidation, decay/prune/persist the encoder state

### Storage (`Kudzu.Storage`)

Add a DETS table for encoder state alongside `traces_warm.dets` and `hologram_registry.dets`.

### MCP Tools

Add new MCP tools for memory operations that use the improved encoder:

- `kudzu_recall` — query traces by semantic similarity to a natural language query
- `kudzu_associations` — show co-occurrence neighbors for a token
- `kudzu_vocabulary` — list known tokens and their frequency

### Context Generation (`kudzu-context.py`)

Future: replace keyword-based categorization with HRR-based similarity queries. A trace's section in MEMORY.md would be determined by probing its vector against section-prototype vectors, not by string matching.

## Module Structure

```
lib/kudzu/hrr/
  encoder.ex          # Updated: token-based encoding with co-occurrence
  encoder_state.ex    # New: EncoderState struct and persistence
  tokenizer.ex        # New: text extraction, tokenization, stopwords, bigrams
```

Changes to existing modules:
- `consolidation.ex` — pass encoder state, update co-occurrence during cycles
- `storage.ex` — add DETS table for encoder state

## Success Criteria

1. Two traces about the same concept with different wording have HRR similarity > 0.3
2. Unrelated traces have HRR similarity < 0.1
3. After 50+ traces, co-occurrence neighbors for domain terms (e.g., "supervision") include related terms (e.g., "otp", "genserver", "tree")
4. Encoding a single trace takes < 10ms
5. Full consolidation cycle with co-occurrence update takes < 5 seconds for 1000 traces
6. Encoder state persists across Kudzu restarts

## Implementation Order

1. `Kudzu.HRR.Tokenizer` — tokenization, stopwords, bigrams
2. `Kudzu.HRR.EncoderState` — state struct, DETS persistence, co-occurrence operations
3. Update `Kudzu.HRR.Encoder` — replace `encode_content` with token-seeded bundling + co-occurrence blending
4. Update `Kudzu.Consolidation` — wire encoder state into consolidation cycles
5. Verify — write tests, manually test similarity between related traces
6. MCP tools — `kudzu_recall`, `kudzu_associations`, `kudzu_vocabulary`

## Future Evolution

- **Contextual decay**: Co-occurrence weights for a project hologram could differ from the global matrix, allowing domain-specific semantic spaces
- **Trace clustering**: Use HRR similarity to automatically group related traces during deep consolidation, forming "memory clusters" that consolidate into single summary traces
- **Claude API integration**: Phase 2 adds Claude as a cognition backend. The encoder remains Kudzu-native; Claude uses the semantic retrieval but doesn't power it
- **Cross-node vocabulary**: In distributed Kudzu, co-occurrence matrices could be merged across mesh nodes using CRDTs, allowing collective semantic learning
