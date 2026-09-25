# Claude Integration with Kudzu Memory System

Claude uses the Kudzu distributed memory system for persistent context, learning, and distributed cognition across sessions.

## Quick Start

Context is loaded automatically at session start via a SessionStart hook.
MEMORY.md is regenerated from Kudzu traces each session — no manual init needed.

```bash
# Record important context (during session)
/home/eel/claude/scripts/kudzu-session.sh record observation "discovered X"
/home/eel/claude/scripts/kudzu-session.sh learn "pattern Y works well for Z"

# End session with summary
/home/eel/claude/scripts/kudzu-session.sh end "Fixed bugs, added features"
```

## API Key (required)

Every Kudzu API call except `/health` needs a bearer key. The helper scripts read it from
`$KUDZU_API_KEY`, or else from the first line of `$KUDZU_API_KEY_FILE`
(default `~/.kudzu/api_key`, keep it `chmod 600`). It is never hardcoded. The key is sent to
titan over the SSH channel's stdin, never on a command line. Without a valid key the
SessionStart hook writes a fallback MEMORY.md that names the problem.

```bash
umask 077; ssh titan 'eval "$(grep -E "^export KUDZU_API_KEY=" ~/.bashrc)"; printf "%s\n" "$KUDZU_API_KEY"' > ~/.kudzu/api_key
```

Other overrides: `KUDZU_HOST` (ssh host, default `titan`), `KUDZU_URL`, `KUDZU_STATE_DIR`,
`KUDZU_MEMORY_MD` (hook output; default derives from `$CLAUDE_PROJECT_DIR`).

## Architecture

### Core Holograms (Always Running)

| Hologram | Purpose | Constitution | Role |
|----------|---------|--------------|------|
| `claude_memory` | Session context, user preferences | kudzu_evolve | Primary memory store |
| `claude_research` | Discoveries, findings | mesh_republic | Research knowledge base |
| `claude_learning` | Patterns, meta-learning | kudzu_evolve | Tracks what works |

All core holograms are peers and share traces automatically.

### Project Holograms

Each major project gets its own hologram connected to core holograms:

```bash
# Create project hologram
/home/eel/claude/scripts/kudzu-project.sh create myproject

# Record project-specific traces
/home/eel/claude/scripts/kudzu-project.sh record myproject decision "chose X because Y"

# Query project history
/home/eel/claude/scripts/kudzu-project.sh query myproject
```

### Distributed Cognition

For complex problems, spawn specialist holograms for parallel exploration:

```bash
# Spawn 4 specialists to explore a question
/home/eel/claude/scripts/kudzu-explore.sh spawn "How should we implement caching?" 4

# View their findings
/home/eel/claude/scripts/kudzu-explore.sh query <exploration_id>

# Get synthesized answer
/home/eel/claude/scripts/kudzu-explore.sh synthesize <exploration_id>

# Clean up when done
/home/eel/claude/scripts/kudzu-explore.sh cleanup <exploration_id>
```

## Session Workflow

### At Session Start (Automatic)

Context is loaded automatically via a SessionStart hook that runs `kudzu-context.sh`:
- Queries all Kudzu holograms for traces
- Generates MEMORY.md with categorized, deduplicated, ranked content
- Claude starts every session pre-loaded with accumulated knowledge

Manual start is no longer needed. To force a refresh mid-session:
```bash
/home/eel/claude/scripts/kudzu-context.sh
```

### During Session

Record significant events:
- **Observations**: Things noticed or discovered
- **Decisions**: Choices made and rationale
- **Learnings**: Patterns that worked or didn't
- **Research**: Findings from investigation

```bash
kudzu-session.sh record <purpose> "content"
kudzu-session.sh learn "pattern description"
kudzu-session.sh research "finding description"
```

### At Session End

```bash
kudzu-session.sh end "Brief summary of what was accomplished"
```

## API Access

Kudzu listens on titan's Tailscale address, **`100.70.67.110:4001`** (REST `/api/v1`,
MCP `/mcp`, WebSocket `/socket`), not on `localhost` and not on port 4000.
`/health` is the only unauthenticated endpoint; everything else needs
`Authorization: Bearer <key>`. `KUDZU_API_KEY` keys have full (mutate) scope;
`KUDZU_API_READ_KEY` keys are read-only (list / get / check). On titan the key is in
`~/.bashrc`; prefer the helper scripts, which never put it on a command line.

```bash
# Health check (no key needed)
ssh titan "curl -s http://100.70.67.110:4001/health"

# Anything else: read the key on titan and pass it as a header file
ssh titan 'eval "$(grep -E "^export KUDZU_API_KEY=" ~/.bashrc)";
  curl -s -H @<(printf "Authorization: Bearer %s\n" "${KUDZU_API_KEY%%,*}") \
    http://100.70.67.110:4001/api/v1/holograms?limit=1000'

# Node metrics: process count, memory, consolidation, brain (no key needed)
ssh titan "curl -s http://100.70.67.110:4001/metrics"
```

## Trace Purposes

| Purpose | Use For |
|---------|---------|
| `observation` | Things noticed, facts discovered |
| `thought` | Reasoning, analysis |
| `memory` | Context to remember |
| `discovery` | Research findings |
| `learning` | Patterns, meta-learning |
| `session_context` | Session summaries |
| `decision` | Choices and rationale |

## Constitutional Frameworks

| Framework | Philosophy | Use For |
|-----------|------------|---------|
| `mesh_republic` | Transparent, distributed | Default, research |
| `kudzu_evolve` | Meta-learning | Memory, learning holograms |
| `cautious` | Explicit permission | High-security contexts |

## Machine Access

- **titan** (`titan-super-server`, 100.70.67.110) - Kudzu server (user `eel`), RTX 4090,
  Ollama on 127.0.0.1:11434 (llama4:scout, mistral, llama3.1, ...)
- **radiator** - Claude Code sessions (SessionStart hook runs the scripts below)

## Starting Kudzu

Kudzu runs from `~/kudzu_src` in the tmux session **`kudzu`**. The session runs an
interactive bash (so `~/.bashrc` supplies `KUDZU_API_KEY` and `ANTHROPIC_API_KEY`) that
sources `exla_env.sh` (CUDA libraries for the EXLA GPU backend) and appends all output to
**`~/kudzu_src/kudzu.log`**:

```bash
ssh titan 'cd ~/kudzu_src && tmux new-session -d -s kudzu -c ~/kudzu_src \
  "bash -ic \"source exla_env.sh && mix run --no-halt 2>&1 | tee -a ~/kudzu_src/kudzu.log\""'
```

`ensure_kudzu` in `kudzu-common.sh` does exactly this when `/health` fails. Watch it live with
`ssh -t titan tmux attach -t kudzu` (detach: Ctrl-b d). Startup reconstruction of ~190
holograms takes about 15-30 s; the Brain initializes once it completes.

## Script Locations

- `/home/eel/claude/scripts/kudzu-context.sh` - SessionStart hook (auto-generates MEMORY.md)
- `/home/eel/claude/scripts/kudzu-context.py` - Consolidation engine (called by context.sh)
- `/home/eel/claude/scripts/kudzu-session.sh` - Mid-session recording
- `/home/eel/claude/scripts/kudzu-project.sh` - Project management
- `/home/eel/claude/scripts/kudzu-explore.sh` - Distributed cognition
- `/home/eel/claude/scripts/kudzu-init.sh` - Basic initialization

## Best Practices

1. **Record decisions** with rationale for future reference
2. **Record learnings** when you discover what works
3. **Use project holograms** for project-specific context
4. **Use distributed cognition** for complex multi-faceted problems
5. **End sessions** with a summary trace

## Troubleshooting

```bash
# Is it up? (health) / how is it doing? (metrics: process_count should stay ~900)
ssh titan "curl -s http://100.70.67.110:4001/health"
ssh titan "curl -s http://100.70.67.110:4001/metrics"

# Recent log / errors
ssh titan "tail -n 100 ~/kudzu_src/kudzu.log"
ssh titan "grep -a '\[error\]' ~/kudzu_src/kudzu.log | tail"

# Restart: SIGTERM is a graceful shutdown (persists hologram state), then start as above
ssh titan 'kill -TERM $(pgrep -f "beam.smp.*-- -home /home/eel"); sleep 5; tmux ls'

# GPU: Kudzu allocates on demand, capped at 40% of the 4090 (config :exla, :clients)
ssh titan "nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv"
```

## License

All MeshRepublic projects use AGPL-3.0. Template at `/home/eel/templates/LICENSE-AGPL-3.0`.
