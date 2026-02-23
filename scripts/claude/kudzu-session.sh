#!/bin/bash
set -euo pipefail
#
# Kudzu Session Management for Claude
# Usage:
#   kudzu-session.sh start [project]  - Initialize session, query relevant context
#   kudzu-session.sh end "summary"    - Record session summary
#   kudzu-session.sh record <purpose> "content"  - Record a trace
#   kudzu-session.sh query [purpose]  - Query traces
#   kudzu-session.sh learn "pattern"  - Record a learning
#   kudzu-session.sh research "finding" - Record a research finding
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUDZU_LOG_PREFIX="kudzu"
source "$SCRIPT_DIR/kudzu-common.sh"

HOLOGRAM_FILE="$KUDZU_STATE_DIR/session_holograms"

# Core hologram IDs (populated on start or loaded from file)
MEMORY_ID=""
RESEARCH_ID=""
LEARNING_ID=""

# Load hologram IDs from state file
load_from_file() {
    if [ -f "$HOLOGRAM_FILE" ]; then
        # Parse key=value safely instead of sourcing
        while IFS='=' read -r key value; do
            case "$key" in
                MEMORY_ID)   MEMORY_ID="$value" ;;
                RESEARCH_ID) RESEARCH_ID="$value" ;;
                LEARNING_ID) LEARNING_ID="$value" ;;
            esac
        done < "$HOLOGRAM_FILE"
    fi
}

# Load or create core holograms
load_holograms() {
    MEMORY_ID=$(get_hologram_id "claude_memory")
    RESEARCH_ID=$(get_hologram_id "claude_research")
    LEARNING_ID=$(get_hologram_id "claude_learning")

    if [ -z "$MEMORY_ID" ]; then
        log_info "Creating claude_memory hologram..."
        MEMORY_ID=$(create_hologram "claude_memory" "kudzu_evolve" '["Remember context", "Surface history", "Learn from interactions"]')
    fi

    if [ -z "$RESEARCH_ID" ]; then
        log_info "Creating claude_research hologram..."
        RESEARCH_ID=$(create_hologram "claude_research" "mesh_republic" '["Discover information", "Share findings", "Build connections"]')
    fi

    if [ -z "$LEARNING_ID" ]; then
        log_info "Creating claude_learning hologram..."
        LEARNING_ID=$(create_hologram "claude_learning" "kudzu_evolve" '["Learn patterns", "Track success", "Propagate strategies"]')
    fi

    # Save to state file
    ensure_state_dir
    cat > "$HOLOGRAM_FILE" << EOF
MEMORY_ID=$MEMORY_ID
RESEARCH_ID=$RESEARCH_ID
LEARNING_ID=$LEARNING_ID
EOF
    chmod 600 "$HOLOGRAM_FILE"
}

# Start session
cmd_start() {
    local project="${1:-general}"

    log_info "=== Kudzu Session Start ==="

    ensure_kudzu || exit 1
    load_holograms

    log_success "Holograms loaded:"
    echo "  Memory:   $MEMORY_ID"
    echo "  Research: $RESEARCH_ID"
    echo "  Learning: $LEARNING_ID"

    # Record session start
    local safe_project
    safe_project=$(json_escape "$project")
    local safe_host
    safe_host=$(json_escape "$(hostname)")
    record_trace "$MEMORY_ID" "session_context" "Session started" ", \"project\": \"${safe_project}\", \"machine\": \"${safe_host}\""

    # Query recent context
    log_info ""
    log_info "Recent memory traces:"
    query_traces "$MEMORY_ID" "" 5 | format_traces 5

    log_info ""
    log_info "Recent learnings:"
    query_traces "$LEARNING_ID" "learning" 3 | format_traces 3

    echo ""
    log_success "Session initialized. Use 'kudzu-session.sh record <purpose> \"content\"' to record traces."
}

# End session
cmd_end() {
    local summary="$1"

    load_from_file
    if [ -z "$MEMORY_ID" ]; then
        ensure_kudzu || exit 1
        load_holograms
    fi

    log_info "=== Kudzu Session End ==="

    record_trace "$MEMORY_ID" "session_context" "$summary" ", \"type\": \"session_end\""

    log_success "Session summary recorded"
}

# Record command
cmd_record() {
    local purpose="$1"
    local content="$2"

    load_from_file
    if [ -z "$MEMORY_ID" ]; then
        ensure_kudzu || exit 1
        load_holograms
    fi

    # Route to appropriate hologram based on purpose
    case "$purpose" in
        learning|pattern|success|failure)
            record_trace "$LEARNING_ID" "learning" "$content"
            ;;
        research|discovery|finding)
            record_trace "$RESEARCH_ID" "discovery" "$content"
            ;;
        *)
            record_trace "$MEMORY_ID" "$purpose" "$content"
            ;;
    esac
}

# Query command
cmd_query() {
    local purpose="${1:-}"

    load_from_file
    if [ -z "$MEMORY_ID" ]; then
        ensure_kudzu || exit 1
        load_holograms
    fi

    log_info "Traces from all holograms:"
    echo ""
    echo "=== Memory ==="
    query_traces "$MEMORY_ID" "$purpose" 5 | python3 -m json.tool 2>/dev/null || query_traces "$MEMORY_ID" "$purpose" 5
    echo ""
    echo "=== Research ==="
    query_traces "$RESEARCH_ID" "$purpose" 5 | python3 -m json.tool 2>/dev/null || query_traces "$RESEARCH_ID" "$purpose" 5
    echo ""
    echo "=== Learning ==="
    query_traces "$LEARNING_ID" "$purpose" 5 | python3 -m json.tool 2>/dev/null || query_traces "$LEARNING_ID" "$purpose" 5
}

# Learn command (shortcut)
cmd_learn() {
    local pattern="$1"
    cmd_record "learning" "$pattern"
}

# Research command (shortcut)
cmd_research() {
    local finding="$1"
    cmd_record "research" "$finding"
}

# Main
case "${1:-}" in
    start)
        cmd_start "${2:-}"
        ;;
    end)
        cmd_end "${2:-Session ended}"
        ;;
    record)
        [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "Usage: $0 record <purpose> \"content\""; exit 1; }
        cmd_record "$2" "$3"
        ;;
    query)
        cmd_query "${2:-}"
        ;;
    learn)
        [ -z "${2:-}" ] && { echo "Usage: $0 learn \"pattern\""; exit 1; }
        cmd_learn "$2"
        ;;
    research)
        [ -z "${2:-}" ] && { echo "Usage: $0 research \"finding\""; exit 1; }
        cmd_research "$2"
        ;;
    *)
        echo "Kudzu Session Manager"
        echo ""
        echo "Usage:"
        echo "  $0 start [project]        - Initialize session"
        echo "  $0 end \"summary\"          - Record session summary"
        echo "  $0 record <purpose> \"msg\" - Record a trace"
        echo "  $0 query [purpose]        - Query traces"
        echo "  $0 learn \"pattern\"        - Record a learning"
        echo "  $0 research \"finding\"     - Record a finding"
        echo ""
        echo "Purposes: observation, thought, memory, discovery, learning, session_context"
        ;;
esac
