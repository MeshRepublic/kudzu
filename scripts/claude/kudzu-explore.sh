#!/bin/bash
set -euo pipefail
#
# Kudzu Distributed Cognition - Parallel Exploration
# Spawns specialist holograms to explore different aspects of a problem
#
# Usage:
#   kudzu-explore.sh spawn "question" [num_specialists]
#   kudzu-explore.sh query <exploration_id>
#   kudzu-explore.sh synthesize <exploration_id>
#   kudzu-explore.sh cleanup <exploration_id>
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUDZU_LOG_PREFIX="explore"
source "$SCRIPT_DIR/kudzu-common.sh"

EXPLORATION_DIR="$KUDZU_STATE_DIR/explorations"

# Generate a unique exploration ID using urandom
gen_id() {
    head -c 16 /dev/urandom | md5sum | head -c 8
}

# Read a field from exploration JSON file
read_exploration() {
    local file="$1"
    local field="$2"
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get(sys.argv[2], ''))
" "$file" "$field" 2>/dev/null
}

# Read specialists list from exploration JSON file
read_specialists() {
    local file="$1"
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for s in data.get('specialists', []):
    print(f\"{s['id']}:{s['name']}\")
" "$file" 2>/dev/null
}

# Spawn specialists for parallel exploration
cmd_spawn() {
    local question="$1"
    local num_specialists="${2:-3}"

    # Validate num_specialists is a positive integer
    if ! [[ "$num_specialists" =~ ^[1-9][0-9]*$ ]]; then
        log_error "num_specialists must be a positive integer, got: $num_specialists"
        return 1
    fi

    local exploration_id
    exploration_id=$(gen_id)
    local exploration_file="$EXPLORATION_DIR/$exploration_id.json"

    mkdir -p "$EXPLORATION_DIR"

    log_info "=== Distributed Exploration ==="
    log_info "Question: $question"
    log_info "Spawning $num_specialists specialists..."
    echo ""

    # Define specialist perspectives
    local -a perspective_names=("analytical" "creative" "critical" "practical" "historical")
    local -a perspective_desires=(
        "Analyze the problem systematically, break it into components"
        "Think creatively, consider unconventional approaches"
        "Be skeptical, identify potential issues and edge cases"
        "Focus on pragmatic solutions, consider implementation"
        "Consider precedents, what has worked before"
    )

    # Initialize exploration file as JSON
    python3 -c "
import json, sys
json.dump({
    'exploration_id': sys.argv[1],
    'question': sys.argv[2],
    'specialists': []
}, open(sys.argv[3], 'w'), indent=2)
" "$exploration_id" "$question" "$exploration_file"
    chmod 600 "$exploration_file"

    local -a specialist_ids=()

    for i in $(seq 1 "$num_specialists"); do
        local idx=$(( (i - 1) % ${#perspective_names[@]} ))
        local name="${perspective_names[$idx]}"
        local desire="${perspective_desires[$idx]}"

        echo -e "${CYAN}[specialist]${NC} Spawning $name specialist..."

        local safe_desire
        safe_desire=$(json_escape "$desire")
        local hologram_id
        hologram_id=$(create_hologram "specialist" "mesh_republic" "[\"${safe_desire}\", \"Share findings with peers\", \"Explore thoroughly\"]")

        if [ -n "$hologram_id" ]; then
            log_success "  $name: $hologram_id"

            # Connect to previously created specialists (bidirectional)
            for prev_id in "${specialist_ids[@]}"; do
                add_peer "$hologram_id" "$prev_id"
            done

            specialist_ids+=("$hologram_id")

            # Add to exploration file
            python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
data['specialists'].append({'id': sys.argv[2], 'name': sys.argv[3]})
json.dump(data, open(sys.argv[1], 'w'), indent=2)
" "$exploration_file" "$hologram_id" "$name"
        fi
    done

    echo ""
    log_info "Stimulating specialists with question..."
    echo ""

    # Stimulate each specialist with the question
    for spec in $(read_specialists "$exploration_file"); do
        local id="${spec%%:*}"
        local name="${spec##*:}"

        echo -e "${CYAN}[specialist]${NC} Asking $name..."

        local answer
        answer=$(stimulate_hologram "$id" "$question")

        echo -e "  ${CYAN}$name:${NC} $answer"
        echo ""
    done

    log_success "Exploration $exploration_id complete"
    log_info "Use 'kudzu-explore.sh query $exploration_id' to see all traces"
    log_info "Use 'kudzu-explore.sh synthesize $exploration_id' to get synthesis"
    log_info "Use 'kudzu-explore.sh cleanup $exploration_id' to remove specialists"
}

# Query exploration traces
cmd_query() {
    local exploration_id="$1"
    local exploration_file="$EXPLORATION_DIR/$exploration_id.json"

    if [ ! -f "$exploration_file" ]; then
        log_error "Exploration $exploration_id not found"
        return 1
    fi

    local question
    question=$(read_exploration "$exploration_file" "question")

    log_info "=== Exploration $exploration_id ==="
    log_info "Question: $question"
    echo ""

    for spec in $(read_specialists "$exploration_file"); do
        local id="${spec%%:*}"
        local name="${spec##*:}"

        echo -e "${CYAN}=== $name ($id) ===${NC}"
        query_traces "$id" "" 5 | format_traces 5
        echo ""
    done
}

# Synthesize findings
cmd_synthesize() {
    local exploration_id="$1"
    local exploration_file="$EXPLORATION_DIR/$exploration_id.json"

    if [ ! -f "$exploration_file" ]; then
        log_error "Exploration $exploration_id not found"
        return 1
    fi

    local question
    question=$(read_exploration "$exploration_file" "question")

    log_info "=== Synthesizing Exploration $exploration_id ==="
    log_info "Gathering all specialist insights..."
    echo ""

    # Collect all traces
    local all_insights=""
    for spec in $(read_specialists "$exploration_file"); do
        local id="${spec%%:*}"
        local name="${spec##*:}"

        local traces
        traces=$(query_traces "$id" "" 10)
        local insight
        insight=$(echo "$traces" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    insights = []
    name = sys.argv[1]
    for t in data.get('traces', []):
        hint = t.get('reconstruction_hint', {})
        content = hint.get('content', '')
        if content:
            insights.append(f'{name}: {content}')
    print(' | '.join(insights))
except Exception:
    pass
" "$name" 2>/dev/null)
        [ -n "$insight" ] && all_insights="$all_insights $insight"
    done

    # Get memory hologram to synthesize
    local memory_id
    memory_id=$(get_hologram_id "claude_memory")

    if [ -n "$memory_id" ]; then
        log_info "Asking memory hologram to synthesize..."

        local synthesis_prompt="Synthesize these specialist perspectives on the question '$question': $all_insights. Provide a balanced summary."

        local answer
        answer=$(stimulate_hologram "$memory_id" "$synthesis_prompt")

        echo ""
        log_success "=== Synthesis ==="
        echo "$answer"
    else
        log_error "Memory hologram not found for synthesis"
    fi
}

# Cleanup exploration
cmd_cleanup() {
    local exploration_id="$1"
    local exploration_file="$EXPLORATION_DIR/$exploration_id.json"

    if [ ! -f "$exploration_file" ]; then
        log_error "Exploration $exploration_id not found"
        return 1
    fi

    log_info "Cleaning up exploration $exploration_id..."

    for spec in $(read_specialists "$exploration_file"); do
        local id="${spec%%:*}"
        local name="${spec##*:}"

        kudzu_api_delete "/api/v1/holograms/$id" > /dev/null
        log_info "  Removed $name ($id)"
    done

    rm -f "$exploration_file"
    log_success "Exploration cleaned up"
}

# Main
case "${1:-}" in
    spawn)
        [ -z "${2:-}" ] && { echo "Usage: $0 spawn \"question\" [num_specialists]"; exit 1; }
        cmd_spawn "$2" "${3:-3}"
        ;;
    query)
        [ -z "${2:-}" ] && { echo "Usage: $0 query <exploration_id>"; exit 1; }
        cmd_query "$2"
        ;;
    synthesize)
        [ -z "${2:-}" ] && { echo "Usage: $0 synthesize <exploration_id>"; exit 1; }
        cmd_synthesize "$2"
        ;;
    cleanup)
        [ -z "${2:-}" ] && { echo "Usage: $0 cleanup <exploration_id>"; exit 1; }
        cmd_cleanup "$2"
        ;;
    *)
        echo "Kudzu Distributed Cognition"
        echo ""
        echo "Spawn specialist holograms for parallel problem exploration"
        echo ""
        echo "Usage:"
        echo "  $0 spawn \"question\" [n]     - Spawn n specialists to explore"
        echo "  $0 query <id>               - View exploration traces"
        echo "  $0 synthesize <id>          - Synthesize findings"
        echo "  $0 cleanup <id>             - Remove specialist holograms"
        echo ""
        echo "Example:"
        echo "  $0 spawn \"How should we implement caching?\" 4"
        ;;
esac
