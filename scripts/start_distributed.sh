#!/bin/bash
#
# Start Kudzu in distributed mode over Tailscale
#
# Usage:
#   ./scripts/start_distributed.sh [node_name] [cookie]
#
# Examples:
#   ./scripts/start_distributed.sh                        # Auto-detect Tailscale IP
#   ./scripts/start_distributed.sh kudzu@<your-ip>        # Specific node name
#   ./scripts/start_distributed.sh auto <your-cookie>     # Auto IP with custom cookie
#
# The script will:
#   1. Detect your Tailscale IP (or use provided node name)
#   2. Start Elixir with distributed node settings
#   3. Configure epmd to listen on the Tailscale interface
#

set -e

# Cookie configuration
# SECURITY: The cookie is the shared secret for Erlang distribution.
# For production, set KUDZU_COOKIE environment variable or pass as argument.
# A random cookie will be generated if not provided, but nodes must share the same cookie.
generate_cookie() {
    # Generate a secure random cookie
    if command -v openssl &> /dev/null; then
        openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
    else
        head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32
    fi
}

# Use environment variable, or argument, or generate new cookie
DEFAULT_COOKIE="${KUDZU_COOKIE:-}"
if [ -z "$DEFAULT_COOKIE" ]; then
    echo "WARNING: No KUDZU_COOKIE set. Generating random cookie."
    echo "         To connect nodes, set KUDZU_COOKIE environment variable to the same value on all nodes."
    DEFAULT_COOKIE=$(generate_cookie)
fi

# Get Tailscale IP
get_tailscale_ip() {
    # Try tailscale ip first
    if command -v tailscale &> /dev/null; then
        tailscale ip -4 2>/dev/null | head -1
    else
        # Fallback: look for tailscale interface
        ip addr show tailscale0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1
    fi
}

# Parse arguments
NODE_NAME="${1:-auto}"
COOKIE="${2:-$DEFAULT_COOKIE}"

# Auto-detect node name if needed
if [ "$NODE_NAME" = "auto" ]; then
    TAILSCALE_IP=$(get_tailscale_ip)
    if [ -z "$TAILSCALE_IP" ]; then
        echo "Error: Could not detect Tailscale IP. Is Tailscale running?"
        echo "Usage: $0 [node_name] [cookie]"
        echo "Example: $0 kudzu@<your-ip> <your-cookie>"
        exit 1
    fi
    NODE_NAME="kudzu@${TAILSCALE_IP}"
    echo "Auto-detected Tailscale IP: $TAILSCALE_IP"
fi

echo "Starting Kudzu distributed node..."
echo "  Node name: $NODE_NAME"
echo "  Cookie: $COOKIE"
echo ""
echo "To connect from another node:"
echo "  Kudzu.Distributed.connect(\"$NODE_NAME\")"
echo ""

# Set ERL_FLAGS for distributed Erlang
export ERL_AFLAGS="-proto_dist inet_tcp"

# Start IEx with distributed settings
exec iex \
    --name "$NODE_NAME" \
    --cookie "$COOKIE" \
    --erl "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9200" \
    -S mix
