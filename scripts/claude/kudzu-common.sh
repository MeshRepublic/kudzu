#!/bin/bash
#
# Kudzu Common Library
# Shared functions for all kudzu-*.sh scripts
#
# Usage: source this file from other scripts
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/kudzu-common.sh"
#

# === Configuration ===

KUDZU_HOST="${KUDZU_HOST:-titan}"
KUDZU_URL="http://localhost:4000"
KUDZU_STATE_DIR="${KUDZU_STATE_DIR:-$HOME/.kudzu}"
KUDZU_SSH_TIMEOUT="${KUDZU_SSH_TIMEOUT:-10}"
KUDZU_CURL_TIMEOUT="${KUDZU_CURL_TIMEOUT:-15}"
KUDZU_LLM_TIMEOUT="${KUDZU_LLM_TIMEOUT:-120}"

# === Colors ===

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Logging ===
# Override KUDZU_LOG_PREFIX in each script before sourcing, or after.
# Default prefix is "kudzu".

KUDZU_LOG_PREFIX="${KUDZU_LOG_PREFIX:-kudzu}"

log_info()    { echo -e "${BLUE}[${KUDZU_LOG_PREFIX}]${NC} $1"; }
log_success() { echo -e "${GREEN}[${KUDZU_LOG_PREFIX}]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[${KUDZU_LOG_PREFIX}]${NC} $1"; }
log_error()   { echo -e "${RED}[${KUDZU_LOG_PREFIX}]${NC} $1"; }

# === State Directory ===

ensure_state_dir() {
    mkdir -p "$KUDZU_STATE_DIR"
}

# === JSON Utilities ===

# Escape a string for safe inclusion in JSON values.
# Usage: local safe=$(json_escape "$user_input")
#        Then use: "{\"key\": \"$safe\"}"
json_escape() {
    python3 -c "import sys, json; print(json.dumps(sys.stdin.read().strip())[1:-1])" <<< "$1"
}

# Parse a field from a JSON response.
# Usage: parse_json_field "$json" "hologram.id"
#        parse_json_field "$json" "status"
# Supports one level of nesting with dot notation.
parse_json_field() {
    local json="$1"
    local field="$2"

    python3 -c "
import sys, json, functools
try:
    data = json.load(sys.stdin)
    keys = sys.argv[1].split('.')
    val = functools.reduce(lambda d, k: d.get(k, {}), keys[:-1], data)
    result = val.get(keys[-1], '') if isinstance(val, dict) else ''
    print(result)
except Exception:
    print('')
" "$field" <<< "$json"
}

# === SSH / API Helpers ===

# Run a command on the Kudzu host via SSH.
# Checks connectivity and quotes the host properly.
# Usage: kudzu_ssh "curl -s http://localhost:4000/health"
kudzu_ssh() {
    local cmd="$1"
    local result
    if ! result=$(ssh -o ConnectTimeout="$KUDZU_SSH_TIMEOUT" -o ServerAliveInterval=30 -o BatchMode=yes "$KUDZU_HOST" "$cmd" 2>/dev/null); then
        log_error "SSH to $KUDZU_HOST failed"
        return 1
    fi
    echo "$result"
}

# Make an API GET request to the Kudzu server.
# Usage: kudzu_api_get "/api/v1/holograms"
kudzu_api_get() {
    local path="$1"
    kudzu_ssh "curl -s --max-time $KUDZU_CURL_TIMEOUT '${KUDZU_URL}${path}'"
}

# Make an API POST request to the Kudzu server.
# Usage: kudzu_api_post "/api/v1/holograms" '{"purpose":"test"}'
#        kudzu_api_post "/api/v1/holograms/id/stimulate" '{"stimulus":"..."}' 120
# The JSON body is passed via base64 to avoid shell quoting issues.
# Optional third argument overrides the curl timeout (for slow LLM calls).
kudzu_api_post() {
    local path="$1"
    local json_body="$2"
    local timeout="${3:-$KUDZU_CURL_TIMEOUT}"

    kudzu_ssh "echo '$(echo "$json_body" | base64)' | base64 -d | curl -s --max-time $timeout -X POST '${KUDZU_URL}${path}' -H 'Content-Type: application/json' -d @-"
}

# Make an API DELETE request to the Kudzu server.
# Usage: kudzu_api_delete "/api/v1/holograms/<id>"
kudzu_api_delete() {
    local path="$1"
    kudzu_ssh "curl -s --max-time $KUDZU_CURL_TIMEOUT -X DELETE '${KUDZU_URL}${path}'"
}

# === Kudzu Health ===

# Check if Kudzu is running on the remote host.
check_kudzu() {
    local health
    health=$(kudzu_api_get "/health" 2>/dev/null) || return 1
    echo "$health" | grep -q '"status":"ok"'
}

# Start Kudzu on the remote host if not running.
ensure_kudzu() {
    if ! check_kudzu; then
        log_info "Starting Kudzu on $KUDZU_HOST..."
        kudzu_ssh "cd /home/eel/kudzu_src && elixir --erl '-detached' -S mix run --no-halt" || return 1
        sleep 5
        if ! check_kudzu; then
            log_error "Could not start Kudzu"
            return 1
        fi
    fi
    return 0
}

# === Hologram Helpers ===

# Get a hologram ID by its purpose.
# Usage: local id=$(get_hologram_id "claude_memory")
get_hologram_id() {
    local purpose="$1"
    local safe_purpose
    safe_purpose=$(json_escape "$purpose")

    local response
    response=$(kudzu_api_get "/api/v1/holograms") || return 1

    echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    purpose = sys.argv[1]
    result = next((h['id'] for h in data.get('holograms', []) if h.get('purpose') == purpose), '')
    print(result)
except Exception:
    print('')
" "$purpose" 2>/dev/null
}

# Create a hologram and return its ID.
# Usage: local id=$(create_hologram "claude_memory" "kudzu_evolve" '["desire1", "desire2"]')
create_hologram() {
    local purpose="$1"
    local constitution="$2"
    local desires_json="$3"  # JSON array string, e.g. '["Remember context", "Learn"]'

    local safe_purpose
    safe_purpose=$(json_escape "$purpose")
    local safe_constitution
    safe_constitution=$(json_escape "$constitution")

    local body="{\"purpose\": \"${safe_purpose}\", \"cognition\": true, \"constitution\": \"${safe_constitution}\", \"desires\": ${desires_json}}"

    local response
    response=$(kudzu_api_post "/api/v1/holograms" "$body") || return 1

    parse_json_field "$response" "hologram.id"
}

# Add a bidirectional peer relationship between two holograms.
# Usage: add_peer "hologram_id_1" "hologram_id_2"
add_peer() {
    local id1="$1"
    local id2="$2"

    kudzu_api_post "/api/v1/holograms/${id1}/peers" "{\"peer_id\": \"${id2}\"}" > /dev/null
    kudzu_api_post "/api/v1/holograms/${id2}/peers" "{\"peer_id\": \"${id1}\"}" > /dev/null
}

# === Trace Helpers ===

# Record a trace on a hologram with proper JSON escaping.
# Usage: record_trace "$hologram_id" "observation" "something happened"
#        record_trace "$hologram_id" "session_context" "started" ',"project":"myproj"'
record_trace() {
    local hologram_id="$1"
    local purpose="$2"
    local content="$3"
    local extra_json="${4:-}"

    local safe_purpose
    safe_purpose=$(json_escape "$purpose")
    local safe_content
    safe_content=$(json_escape "$content")

    local body="{\"purpose\": \"${safe_purpose}\", \"data\": {\"content\": \"${safe_content}\", \"timestamp\": \"$(date -Iseconds)\"${extra_json}}}"

    local response
    response=$(kudzu_api_post "/api/v1/holograms/${hologram_id}/traces" "$body") || {
        log_error "Failed to record trace"
        return 1
    }

    echo "$response" | grep -q '"trace"' && log_success "Recorded $purpose trace" || log_error "Failed to record trace"
}

# Query traces from a hologram.
# Usage: query_traces "$hologram_id" "" 10
#        query_traces "$hologram_id" "observation" 5
query_traces() {
    local hologram_id="$1"
    local purpose="${2:-}"
    local limit="${3:-10}"

    local path="/api/v1/holograms/${hologram_id}/traces?limit=${limit}"
    [ -n "$purpose" ] && path="${path}&purpose=${purpose}"

    kudzu_api_get "$path"
}

# Print traces in a human-readable format.
# Usage: echo "$traces_json" | format_traces [max_entries]
format_traces() {
    local max="${1:-10}"
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for t in data.get('traces', [])[:int(sys.argv[1])]:
        purpose = t.get('purpose', 'unknown')
        hint = t.get('reconstruction_hint', {})
        content = hint.get('content', hint.get('key_events', hint.get('event', str(hint)[:100])))
        line = f'  [{purpose}] {content}'
        print(line[:83] + '...' if len(line) > 83 else line)
except Exception:
    pass
" "$max" 2>/dev/null
}

# === Stimulate ===

# Stimulate a hologram and return the response text.
# Usage: local response=$(stimulate_hologram "$id" "What do you know about X?")
stimulate_hologram() {
    local hologram_id="$1"
    local stimulus="$2"

    local safe_stimulus
    safe_stimulus=$(json_escape "$stimulus")

    local body="{\"stimulus\": \"${safe_stimulus}\"}"
    local response
    response=$(kudzu_api_post "/api/v1/holograms/${hologram_id}/stimulate" "$body" "$KUDZU_LLM_TIMEOUT") || return 1

    echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    resp = data.get('response', '')
    for line in resp.split('\n'):
        if line.startswith('RESPOND:'):
            print(line[8:].strip())
            break
    else:
        print(resp[:200] if len(resp) > 200 else resp)
except Exception as e:
    print(f'(no response: {e})')
" 2>/dev/null
}
