#!/bin/bash
set -euo pipefail
#
# Kudzu Node Management
# Setup and manage a Kudzu node on any device
#
# Usage:
#   kudzu-node.sh setup               - First-time setup
#   kudzu-node.sh start [--mesh peer] - Start node (optionally join mesh)
#   kudzu-node.sh status              - Show node status
#   kudzu-node.sh join <peer>         - Join an existing mesh
#   kudzu-node.sh leave               - Leave the mesh (keep running locally)
#   kudzu-node.sh stop                - Stop the node
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUDZU_LOG_PREFIX="kudzu"
source "$SCRIPT_DIR/kudzu-common.sh"

KUDZU_SRC="${KUDZU_SRC:-$HOME/kudzu_src}"
KUDZU_PORT="${KUDZU_PORT:-4000}"
KUDZU_NODE_NAME="${KUDZU_NODE_NAME:-kudzu@$(hostname)}"
KUDZU_PIDFILE="$KUDZU_STATE_DIR/kudzu.pid"

check_deps() {
    local missing=()

    if ! command -v elixir &> /dev/null; then
        missing+=("elixir")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install Elixir: https://elixir-lang.org/install.html"
        return 1
    fi

    return 0
}

cmd_setup() {
    log_info "=== Kudzu Node Setup ==="

    if ! check_deps; then
        return 1
    fi

    # Create data directories
    log_info "Creating data directories..."
    mkdir -p "$KUDZU_STATE_DIR"/{dets,mnesia,logs}

    if [ ! -d "$KUDZU_SRC" ]; then
        log_warn "Kudzu source not found at $KUDZU_SRC"
        log_info "Clone it: git clone https://github.com/MeshRepublic/kudzu.git $KUDZU_SRC"
        return 1
    fi

    # Compile in a subshell to avoid changing working directory
    log_info "Compiling Kudzu..."
    if (cd "$KUDZU_SRC" && mix deps.get && mix compile); then
        log_success "Setup complete!"
        log_info ""
        log_info "Next steps:"
        log_info "  1. Start node:  kudzu-node.sh start"
        log_info "  2. Join mesh:   kudzu-node.sh join kudzu@titan"
        log_info ""
        log_info "API will be available at http://localhost:$KUDZU_PORT"
    else
        log_error "Compilation failed"
        return 1
    fi
}

cmd_start() {
    local mesh_peer=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --mesh)
                mesh_peer="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    log_info "=== Starting Kudzu Node ==="
    log_info "Node: $KUDZU_NODE_NAME"
    log_info "Port: $KUDZU_PORT"
    log_info "Data: $KUDZU_STATE_DIR"

    # Check if already running
    if lsof -ti :"$KUDZU_PORT" > /dev/null 2>&1; then
        log_warn "Port $KUDZU_PORT already in use"
        log_info "Stop existing node first: kudzu-node.sh stop"
        return 1
    fi

    ensure_state_dir
    mkdir -p "$KUDZU_STATE_DIR/logs"

    if [ -n "$mesh_peer" ]; then
        log_info "Will join mesh via $mesh_peer after startup..."
    fi

    # Start in background with full node name (--name, not --sname)
    export KUDZU_DATA_DIR="$KUDZU_STATE_DIR"
    (cd "$KUDZU_SRC" && elixir --name "$KUDZU_NODE_NAME" --erl '-detached' -S mix run --no-halt \
        >> "$KUDZU_STATE_DIR/logs/kudzu.log" 2>&1) &
    local bg_pid=$!

    # Write PID file
    echo "$bg_pid" > "$KUDZU_PIDFILE"

    # Wait for startup
    log_info "Waiting for startup..."
    for i in {1..10}; do
        sleep 1
        if curl -s "http://localhost:$KUDZU_PORT/health" > /dev/null 2>&1; then
            # Update PID file with actual process on the port
            local actual_pid
            actual_pid=$(lsof -ti :"$KUDZU_PORT" 2>/dev/null | head -1)
            [ -n "$actual_pid" ] && echo "$actual_pid" > "$KUDZU_PIDFILE"

            log_success "Node started!"

            # Initialize node
            curl -s -X POST "http://localhost:$KUDZU_PORT/api/v1/node/init" \
                -H "Content-Type: application/json" \
                -d "{\"data_dir\": \"$KUDZU_STATE_DIR\"}" > /dev/null

            # Join mesh if specified
            if [ -n "$mesh_peer" ]; then
                log_info "Joining mesh via $mesh_peer..."
                curl -s -X POST "http://localhost:$KUDZU_PORT/api/v1/node/mesh/join" \
                    -H "Content-Type: application/json" \
                    -d "{\"peer\": \"$mesh_peer\"}"
                echo ""
            fi

            cmd_status
            return 0
        fi
    done

    log_error "Startup timeout - check $KUDZU_STATE_DIR/logs/kudzu.log"
    return 1
}

cmd_status() {
    if ! curl -s "http://localhost:$KUDZU_PORT/health" > /dev/null 2>&1; then
        log_error "Node not running"
        return 1
    fi

    log_info "=== Node Status ==="

    local status
    status=$(curl -s "http://localhost:$KUDZU_PORT/api/v1/node")

    echo "$status" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(f\"  Node:    {data.get('node_name', 'unknown')}\")
    print(f\"  Status:  {data.get('mesh_status', 'unknown')}\")
    print(f\"  Peers:   {data.get('peer_count', 0)}\")
    print(f\"  Uptime:  {data.get('uptime_seconds', 0)}s\")

    storage = data.get('storage', {})
    print(f\"  Storage:\")
    print(f\"    Hot:   {storage.get('hot', 0)} traces\")
    print(f\"    Warm:  {storage.get('warm', 0)} traces\")
    print(f\"    Cold:  {storage.get('cold', 'N/A')} traces\")

    caps = data.get('capabilities', {})
    compute = caps.get('compute', {})
    if compute.get('ollama'):
        print(f\"  Compute: Ollama available\")
    if compute.get('gpu'):
        print(f\"  GPU:     {compute.get('gpu')}\")
except Exception as e:
    print(f\"  Error parsing status: {e}\")
" 2>/dev/null

    # Show connected peers if any
    local peers
    peers=$(curl -s "http://localhost:$KUDZU_PORT/api/v1/node/mesh/peers")
    local peer_count
    peer_count=$(echo "$peers" | python3 -c "import sys,json; print(json.load(sys.stdin).get('peer_count', 0))" 2>/dev/null) || peer_count="0"

    if [ "$peer_count" != "0" ] && [ -n "$peer_count" ]; then
        echo ""
        log_info "Connected Peers:"
        echo "$peers" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for peer in data.get('peers', []):
    print(f'  - {peer}')
" 2>/dev/null
    fi
}

cmd_join() {
    local peer="$1"

    if [ -z "$peer" ]; then
        log_error "Usage: kudzu-node.sh join <peer>"
        log_info "Example: kudzu-node.sh join kudzu@titan"
        return 1
    fi

    if ! curl -s "http://localhost:$KUDZU_PORT/health" > /dev/null 2>&1; then
        log_error "Node not running. Start it first: kudzu-node.sh start"
        return 1
    fi

    log_info "Joining mesh via $peer..."

    local result
    result=$(curl -s -X POST "http://localhost:$KUDZU_PORT/api/v1/node/mesh/join" \
        -H "Content-Type: application/json" \
        -d "{\"peer\": \"$peer\"}")

    echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'error' in data:
    print(f'Error: {data[\"error\"]}')
else:
    print(f'Status: {data.get(\"status\", \"unknown\")}')
    peers = data.get('peers', [])
    print(f'Peers: {len(peers)}')
" 2>/dev/null

    cmd_status
}

cmd_leave() {
    if ! curl -s "http://localhost:$KUDZU_PORT/health" > /dev/null 2>&1; then
        log_error "Node not running"
        return 1
    fi

    log_info "Leaving mesh..."

    curl -s -X POST "http://localhost:$KUDZU_PORT/api/v1/node/mesh/leave" > /dev/null

    log_success "Now operating standalone (local storage still works)"
}

cmd_stop() {
    log_info "Stopping Kudzu node..."

    # Try PID file first
    if [ -f "$KUDZU_PIDFILE" ]; then
        local pid
        pid=$(cat "$KUDZU_PIDFILE")
        if kill "$pid" 2>/dev/null; then
            sleep 1
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            rm -f "$KUDZU_PIDFILE"
            log_success "Node stopped"
            return 0
        fi
        rm -f "$KUDZU_PIDFILE"
    fi

    # Fallback to port-based lookup
    local pid
    pid=$(lsof -ti :"$KUDZU_PORT" 2>/dev/null | head -1)

    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
        fi
        log_success "Node stopped"
    else
        log_warn "No node running on port $KUDZU_PORT"
    fi
}

# Main
case "${1:-}" in
    setup)
        cmd_setup
        ;;
    start)
        shift
        cmd_start "$@"
        ;;
    status)
        cmd_status
        ;;
    join)
        cmd_join "${2:-}"
        ;;
    leave)
        cmd_leave
        ;;
    stop)
        cmd_stop
        ;;
    *)
        echo "Kudzu Node Management"
        echo ""
        echo "Run a full Kudzu node on any device with all storage tiers."
        echo "Optionally join the mesh for distributed memory across devices."
        echo ""
        echo "Usage:"
        echo "  $0 setup               - First-time setup"
        echo "  $0 start [--mesh peer] - Start node"
        echo "  $0 status              - Show node status"
        echo "  $0 join <peer>         - Join mesh (e.g., kudzu@titan)"
        echo "  $0 leave               - Leave mesh, keep local"
        echo "  $0 stop                - Stop node"
        echo ""
        echo "Environment:"
        echo "  KUDZU_STATE_DIR  - Data directory (default: ~/.kudzu)"
        echo "  KUDZU_SRC        - Source directory (default: ~/kudzu_src)"
        echo "  KUDZU_PORT       - API port (default: 4000)"
        echo "  KUDZU_NODE_NAME  - Erlang node name (default: kudzu@hostname)"
        ;;
esac
