#!/bin/bash
#
# Kudzu Context Hook
# Called by Claude Code SessionStart hook.
# Generates MEMORY.md from Kudzu traces.
#
# Exit 0 + stdout text = text added to Claude's context
# Exit 2 = blocking error shown to user
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/kudzu-common.sh" 2>/dev/null || true

# Output path: $KUDZU_MEMORY_MD if set; otherwise the memory dir of the
# Claude Code project this hook runs in ($CLAUDE_PROJECT_DIR, provided to
# hooks), using Claude Code's project-dir naming (non-alphanumerics -> '-').
if [ -n "${KUDZU_MEMORY_MD:-}" ]; then
    MEMORY_MD="$KUDZU_MEMORY_MD"
else
    PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
    MEMORY_MD="$HOME/.claude/projects/$(printf '%s' "$PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')/memory/MEMORY.md"
fi

# Try to ensure Kudzu is running (but don't block session on failure)
ensure_kudzu 2>/dev/null

# Run consolidation engine
python3 "$SCRIPT_DIR/kudzu-context.py" "$MEMORY_MD"
exit $?
