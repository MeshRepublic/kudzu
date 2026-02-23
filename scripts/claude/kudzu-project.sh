#!/bin/bash
set -euo pipefail
#
# Kudzu Project Management
# Manages project-specific holograms with peer relationships to core holograms
#
# Usage:
#   kudzu-project.sh create <project_name> [constitution]
#   kudzu-project.sh list
#   kudzu-project.sh info <project_name>
#   kudzu-project.sh record <project_name> <purpose> "content"
#   kudzu-project.sh query <project_name> [purpose]
#   kudzu-project.sh delete <project_name>
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUDZU_LOG_PREFIX="project"
source "$SCRIPT_DIR/kudzu-common.sh"

PROJECT_REGISTRY="$KUDZU_STATE_DIR/projects.json"

# Ensure registry exists
ensure_registry() {
    ensure_state_dir
    [ -f "$PROJECT_REGISTRY" ] || echo "{}" > "$PROJECT_REGISTRY"
}

# Get project hologram ID from registry (safe: passes project via argv, not interpolation)
get_project_id() {
    local project="$1"
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get(sys.argv[2], {}).get('id', ''))
" "$PROJECT_REGISTRY" "$project" 2>/dev/null
}

# Save project to registry
save_project() {
    local project="$1"
    local hologram_id="$2"
    local constitution="$3"

    python3 -c "
import json, sys
from datetime import datetime
registry = sys.argv[1]
data = json.load(open(registry))
data[sys.argv[2]] = {
    'id': sys.argv[3],
    'constitution': sys.argv[4],
    'created': datetime.now().isoformat()
}
json.dump(data, open(registry, 'w'), indent=2)
" "$PROJECT_REGISTRY" "$project" "$hologram_id" "$constitution"
}

# Remove project from registry
remove_project() {
    local project="$1"
    python3 -c "
import json, sys
registry = sys.argv[1]
data = json.load(open(registry))
data.pop(sys.argv[2], None)
json.dump(data, open(registry, 'w'), indent=2)
" "$PROJECT_REGISTRY" "$project"
}

# Create project hologram
cmd_create() {
    local project="$1"
    local constitution="${2:-mesh_republic}"

    ensure_registry

    # Check if project already exists
    local existing
    existing=$(get_project_id "$project")
    if [ -n "$existing" ]; then
        log_warn "Project '$project' already exists with hologram $existing"
        return 1
    fi

    log_info "Creating project hologram for '$project'..."

    local safe_project
    safe_project=$(json_escape "$project")

    # Create the hologram
    local hologram_id
    hologram_id=$(create_hologram "claude_project" "$constitution" "[\"Track ${safe_project} progress\", \"Remember project decisions\", \"Share learnings with peers\"]")

    if [ -z "$hologram_id" ]; then
        log_error "Failed to create hologram"
        return 1
    fi

    # Save to registry
    save_project "$project" "$hologram_id" "$constitution"

    # Connect to core holograms
    local memory_id
    memory_id=$(get_hologram_id "claude_memory")
    local learning_id
    learning_id=$(get_hologram_id "claude_learning")

    [ -n "$memory_id" ] && add_peer "$hologram_id" "$memory_id"
    [ -n "$learning_id" ] && add_peer "$hologram_id" "$learning_id"

    # Record initial trace
    record_trace "$hologram_id" "session_context" "Project created: $project" ", \"event\": \"project_created\", \"constitution\": \"$(json_escape "$constitution")\""

    log_success "Created project '$project' with hologram $hologram_id"
    log_info "Constitution: $constitution"
    log_info "Connected to core holograms"
}

# List all projects
cmd_list() {
    ensure_registry

    log_info "Registered projects:"
    echo ""

    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
if not data:
    print('  (no projects registered)')
else:
    for name, info in data.items():
        print(f\"  {name}: {info.get('id', 'unknown')} ({info.get('constitution', 'unknown')})\")
" "$PROJECT_REGISTRY"
}

# Show project info
cmd_info() {
    local project="$1"
    ensure_registry

    local hologram_id
    hologram_id=$(get_project_id "$project")
    if [ -z "$hologram_id" ]; then
        log_error "Project '$project' not found"
        return 1
    fi

    log_info "Project: $project"
    log_info "Hologram: $hologram_id"
    echo ""

    kudzu_api_get "/api/v1/holograms/$hologram_id" | python3 -m json.tool 2>/dev/null

    echo ""
    log_info "Recent traces:"
    query_traces "$hologram_id" "" 5 | format_traces 5
}

# Record trace for project
cmd_record() {
    local project="$1"
    local purpose="$2"
    local content="$3"

    local hologram_id
    hologram_id=$(get_project_id "$project")
    if [ -z "$hologram_id" ]; then
        log_error "Project '$project' not found. Create it first with: kudzu-project.sh create $project"
        return 1
    fi

    record_trace "$hologram_id" "$purpose" "$content"
}

# Query project traces
cmd_query() {
    local project="$1"
    local purpose="${2:-}"

    local hologram_id
    hologram_id=$(get_project_id "$project")
    if [ -z "$hologram_id" ]; then
        log_error "Project '$project' not found"
        return 1
    fi

    query_traces "$hologram_id" "$purpose" 20 | python3 -m json.tool 2>/dev/null
}

# Delete project
cmd_delete() {
    local project="$1"

    local hologram_id
    hologram_id=$(get_project_id "$project")
    if [ -z "$hologram_id" ]; then
        log_error "Project '$project' not found"
        return 1
    fi

    log_warn "Deleting project '$project' (hologram $hologram_id)..."

    kudzu_api_delete "/api/v1/holograms/$hologram_id"
    remove_project "$project"

    log_success "Project '$project' deleted"
}

# Main
case "${1:-}" in
    create)
        [ -z "${2:-}" ] && { echo "Usage: $0 create <project_name> [constitution]"; exit 1; }
        cmd_create "$2" "${3:-mesh_republic}"
        ;;
    list)
        cmd_list
        ;;
    info)
        [ -z "${2:-}" ] && { echo "Usage: $0 info <project_name>"; exit 1; }
        cmd_info "$2"
        ;;
    record)
        [ -z "${4:-}" ] && { echo "Usage: $0 record <project_name> <purpose> \"content\""; exit 1; }
        cmd_record "$2" "$3" "$4"
        ;;
    query)
        [ -z "${2:-}" ] && { echo "Usage: $0 query <project_name> [purpose]"; exit 1; }
        cmd_query "$2" "${3:-}"
        ;;
    delete)
        [ -z "${2:-}" ] && { echo "Usage: $0 delete <project_name>"; exit 1; }
        cmd_delete "$2"
        ;;
    *)
        echo "Kudzu Project Manager"
        echo ""
        echo "Usage:"
        echo "  $0 create <name> [constitution]  - Create project hologram"
        echo "  $0 list                          - List all projects"
        echo "  $0 info <name>                   - Show project details"
        echo "  $0 record <name> <purpose> \"msg\" - Record trace"
        echo "  $0 query <name> [purpose]        - Query traces"
        echo "  $0 delete <name>                 - Delete project"
        echo ""
        echo "Constitutions: mesh_republic (default), kudzu_evolve, cautious"
        ;;
esac
