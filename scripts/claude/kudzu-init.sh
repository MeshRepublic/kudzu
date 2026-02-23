#!/bin/bash
set -euo pipefail
#
# Initialize Kudzu for Claude session
# Usage: ./kudzu-init.sh [hologram_id]
#
# Note: kudzu-session.sh is the preferred script for session management.
# This script is a simpler alternative for basic initialization.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUDZU_LOG_PREFIX="kudzu"
source "$SCRIPT_DIR/kudzu-common.sh"

# Main
echo "=== Kudzu Session Initialization ==="

ensure_kudzu || exit 1

echo "Kudzu is running on $KUDZU_HOST"

# Find or create memory hologram
HOLOGRAM_ID="${1:-$(get_hologram_id "claude_memory")}"

if [ -z "$HOLOGRAM_ID" ]; then
    HOLOGRAM_ID=$(create_hologram "claude_memory" "kudzu_evolve" '["Remember context across sessions", "Surface relevant history", "Learn from successful patterns"]')
fi

if [ -z "$HOLOGRAM_ID" ]; then
    echo "ERROR: Could not find or create hologram"
    exit 1
fi

echo "Memory hologram: $HOLOGRAM_ID"
echo ""
echo "Recent traces:"
query_traces "$HOLOGRAM_ID" "" 10 | python3 -m json.tool 2>/dev/null || query_traces "$HOLOGRAM_ID" "" 10

echo ""
echo "Export for session:"
echo "export KUDZU_HOLOGRAM=$HOLOGRAM_ID"
