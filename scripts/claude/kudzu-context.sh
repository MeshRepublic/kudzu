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

MEMORY_MD="$HOME/.claude/projects/-home-eel-claude/memory/MEMORY.md"

# Try to ensure Kudzu is running (but don't block session on failure)
ensure_kudzu 2>/dev/null

# Run consolidation engine
python3 "$SCRIPT_DIR/kudzu-context.py" "$MEMORY_MD"
exit $?
