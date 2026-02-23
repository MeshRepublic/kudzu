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

Direct API access on titan:4000:

```bash
# Health check
ssh titan "curl -s http://localhost:4000/health"

# List holograms
ssh titan "curl -s http://localhost:4000/api/v1/holograms"

# Get hologram details
ssh titan "curl -s http://localhost:4000/api/v1/holograms/<id>"

# Record trace
ssh titan 'curl -s -X POST http://localhost:4000/api/v1/holograms/<id>/traces \
  -H "Content-Type: application/json" \
  -d "{\"purpose\": \"observation\", \"data\": {\"content\": \"...\"}}"'

# Stimulate (LLM interaction)
ssh titan 'curl -s -X POST http://localhost:4000/api/v1/holograms/<id>/stimulate \
  -H "Content-Type: application/json" \
  -d "{\"stimulus\": \"What do you know about X?\"}"'

# Query traces
ssh titan "curl -s http://localhost:4000/api/v1/holograms/<id>/traces?purpose=observation"
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

- **titan** - Kudzu server, Ollama (llama4:scout)
- **radiator** - Claude Code sessions
- **Screen session** - `screen -x claude-collab` on radiator has persistent SSH to titan

## Starting Kudzu

If Kudzu isn't running:
```bash
ssh titan "cd /home/eel/kudzu_src && elixir --erl '-detached' -S mix run --no-halt"
```

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
# Check if Kudzu is running
ssh titan "curl -s http://localhost:4000/health"

# Restart Kudzu
ssh titan "kill \$(lsof -ti :4000); cd /home/eel/kudzu_src && elixir --erl '-detached' -S mix run --no-halt"

# Check holograms
ssh titan "curl -s http://localhost:4000/api/v1/holograms" | python3 -m json.tool
```

## License

All MeshRepublic projects use AGPL-3.0. Template at `/home/eel/templates/LICENSE-AGPL-3.0`.
