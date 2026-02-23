#!/usr/bin/env python3
"""
Kudzu Context Builder - generates MEMORY.md from Kudzu hologram traces.

Queries traces from Kudzu holograms via SSH to titan, categorizes them into
MEMORY.md sections, deduplicates, ranks by recency, and writes a compact
context file suitable for Claude Code hooks.

Usage: python3 kudzu-context.py <memory_md_path>
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

KUDZU_HOST = os.environ.get("KUDZU_HOST", "titan")
KUDZU_URL = "http://localhost:4000"
SSH_TIMEOUT = 10
CURL_TIMEOUT = 15
TRACE_LIMIT = 50
LINE_BUDGET = 180
STATE_DIR = Path.home() / ".kudzu"
HOLOGRAM_FILE = STATE_DIR / "session_holograms"
PROJECTS_FILE = STATE_DIR / "projects.json"

# Keywords used to classify general traces into sub-sections
WORKFLOW_KEYWORDS = {"commit", "rsync", "deploy", "ssh", "git", "workflow",
                     "build", "make", "docker", "screen", "tmux", "script"}
FACT_KEYWORDS = {"machine", "repo", "path", "url", "host", "server", "api",
                 "port", "directory", "ip", "address", "endpoint", "config"}

# ---------------------------------------------------------------------------
# SSH / API helpers
# ---------------------------------------------------------------------------

def ssh_cmd(remote_cmd: str, timeout: int = SSH_TIMEOUT + CURL_TIMEOUT + 5) -> str:
    """Run a command on the Kudzu host via SSH. Returns stdout or raises."""
    args = [
        "ssh",
        "-o", f"ConnectTimeout={SSH_TIMEOUT}",
        "-o", "ServerAliveInterval=30",
        "-o", "BatchMode=yes",
        KUDZU_HOST,
        remote_cmd,
    ]
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(f"SSH failed (rc={result.returncode}): {result.stderr.strip()}")
    return result.stdout


def api_get(path: str) -> dict:
    """GET a JSON endpoint on the Kudzu API."""
    raw = ssh_cmd(f"curl -s --max-time {CURL_TIMEOUT} '{KUDZU_URL}{path}'")
    return json.loads(raw)


def api_post(path: str, body: dict) -> dict:
    """POST JSON to a Kudzu API endpoint using base64 transport."""
    import base64
    encoded = base64.b64encode(json.dumps(body).encode()).decode()
    raw = ssh_cmd(
        f"echo '{encoded}' | base64 -d | "
        f"curl -s --max-time {CURL_TIMEOUT} -X POST "
        f"'{KUDZU_URL}{path}' -H 'Content-Type: application/json' -d @-"
    )
    return json.loads(raw)


# ---------------------------------------------------------------------------
# Hologram discovery
# ---------------------------------------------------------------------------

def load_hologram_ids() -> dict:
    """Load hologram IDs from the state file.

    Returns dict with keys MEMORY_ID, RESEARCH_ID, LEARNING_ID (values may
    be empty strings if the file is missing or incomplete).
    """
    ids = {"MEMORY_ID": "", "RESEARCH_ID": "", "LEARNING_ID": ""}
    try:
        if HOLOGRAM_FILE.exists():
            for line in HOLOGRAM_FILE.read_text().splitlines():
                line = line.strip()
                if "=" in line:
                    key, value = line.split("=", 1)
                    if key in ids:
                        ids[key] = value.strip()
    except OSError:
        pass
    return ids


def discover_hologram_ids() -> dict:
    """Discover hologram IDs from the API and save them."""
    purpose_map = {
        "claude_memory": "MEMORY_ID",
        "claude_research": "RESEARCH_ID",
        "claude_learning": "LEARNING_ID",
    }
    ids = {"MEMORY_ID": "", "RESEARCH_ID": "", "LEARNING_ID": ""}

    try:
        data = api_get("/api/v1/holograms")
        for h in data.get("holograms", []):
            purpose = h.get("purpose", "")
            if purpose in purpose_map:
                ids[purpose_map[purpose]] = h.get("id", "")
    except Exception:
        pass

    return ids


def save_hologram_ids(ids: dict) -> None:
    """Persist hologram IDs to the state file with mode 600."""
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        content = "\n".join(f"{k}={v}" for k, v in sorted(ids.items()) if v) + "\n"
        HOLOGRAM_FILE.write_text(content)
        os.chmod(HOLOGRAM_FILE, 0o600)
    except OSError:
        pass


def get_hologram_ids() -> dict:
    """Get hologram IDs, discovering from API if state file is incomplete."""
    ids = load_hologram_ids()
    if all(ids.values()):
        return ids

    discovered = discover_hologram_ids()
    # Merge: prefer existing non-empty values, fill gaps from discovery
    for key in ids:
        if not ids[key] and discovered[key]:
            ids[key] = discovered[key]

    if any(ids.values()):
        save_hologram_ids(ids)

    return ids


# ---------------------------------------------------------------------------
# Trace fetching
# ---------------------------------------------------------------------------

def get_project_hologram_ids() -> list:
    """Load project hologram IDs from projects.json."""
    try:
        if PROJECTS_FILE.exists():
            data = json.loads(PROJECTS_FILE.read_text())
            return [p["hologram_id"] for p in data.get("projects", []) if p.get("hologram_id")]
    except (OSError, json.JSONDecodeError, KeyError):
        pass
    return []


def fetch_traces(hologram_id: str, limit: int = TRACE_LIMIT) -> list:
    """Fetch traces from a hologram. Returns list of trace dicts."""
    if not hologram_id:
        return []
    try:
        data = api_get(f"/api/v1/holograms/{hologram_id}/traces?limit={limit}")
        return data.get("traces", [])
    except Exception:
        return []


def extract_content(trace: dict) -> str:
    """Extract human-readable content from a trace's reconstruction_hint."""
    hint = trace.get("reconstruction_hint", {})
    if not isinstance(hint, dict):
        return str(hint)[:200] if hint else ""

    # Try known content fields in priority order
    for field in ("content", "summary", "key_events", "event"):
        val = hint.get(field)
        if val and isinstance(val, str):
            return val.strip()

    # Fallback: stringify the hint
    fallback = str(hint)
    return fallback[:200] if len(fallback) > 200 else fallback


def extract_recency(trace: dict) -> int:
    """Extract a recency score from the vector clock timestamp.

    Higher = more recent. Falls back to 0 if parsing fails.
    """
    ts = trace.get("timestamp", {})
    if isinstance(ts, dict):
        # The vector clock is {"node_id": N} — higher N = more recent
        # May have multiple node entries; use the max value
        values = [v for v in ts.values() if isinstance(v, (int, float))]
        return max(values) if values else 0
    return 0


# ---------------------------------------------------------------------------
# Categorization
# ---------------------------------------------------------------------------

def categorize_trace(trace: dict, content: str) -> str:
    """Map a trace to a MEMORY.md section name.

    Returns one of: Learnings, Recent Decisions, Workflows, Key Facts,
    Current State, Active Projects.
    """
    purpose = trace.get("purpose", "")
    content_lower = content.lower()

    if purpose in ("learning", "discovery", "research"):
        return "Learnings"
    if purpose == "decision":
        return "Recent Decisions"
    if purpose == "session_context":
        # Check for project info
        hint = trace.get("reconstruction_hint", {})
        if isinstance(hint, dict) and hint.get("project"):
            return "Active Projects"
        if "project" in content_lower:
            return "Active Projects"
        return "Current State"

    # General traces: observation, thought, memory, or unknown
    if any(kw in content_lower for kw in WORKFLOW_KEYWORDS):
        return "Workflows"
    if any(kw in content_lower for kw in FACT_KEYWORDS):
        return "Key Facts"
    return "Current State"


# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------

def deduplicate(items: list) -> list:
    """Remove entries where a shorter string is a substring of a longer one.

    Each item is a (content, recency) tuple. Keeps the longer/more-recent
    version when duplicates are found.
    """
    if not items:
        return items

    # Sort by content length descending so longer items come first
    sorted_items = sorted(items, key=lambda x: len(x[0]), reverse=True)
    kept = []

    for content, recency in sorted_items:
        normalized = content.strip().lower()
        is_dup = False
        for existing_content, _ in kept:
            if normalized in existing_content.strip().lower():
                is_dup = True
                break
        if not is_dup:
            kept.append((content, recency))

    return kept


# ---------------------------------------------------------------------------
# MEMORY.md generation
# ---------------------------------------------------------------------------

# Section order and headings
SECTION_ORDER = [
    "Current State",
    "Active Projects",
    "Key Facts",
    "Workflows",
    "Learnings",
    "Recent Decisions",
]


def build_sections(all_traces: list) -> dict:
    """Categorize and deduplicate traces into sections.

    Returns {section_name: [(content, recency), ...]}.
    """
    sections = {s: [] for s in SECTION_ORDER}

    for trace in all_traces:
        content = extract_content(trace)
        if not content or content in ("{}", "{}"):
            continue
        recency = extract_recency(trace)
        section = categorize_trace(trace, content)
        if section in sections:
            sections[section].append((content, recency))

    # Deduplicate within each section
    for section in sections:
        sections[section] = deduplicate(sections[section])
        # Sort by recency descending (most recent first)
        sections[section].sort(key=lambda x: x[1], reverse=True)

    return sections


def truncate_line(text: str, max_len: int = 120) -> str:
    """Truncate a single line to max_len characters."""
    text = text.replace("\n", " ").strip()
    if len(text) > max_len:
        return text[:max_len - 3] + "..."
    return text


def render_memory_md(sections: dict) -> str:
    """Render sections into MEMORY.md content within the line budget."""
    lines = []
    lines.append("# Kudzu Memory Context")
    lines.append("")
    lines.append(f"_Auto-generated by kudzu-context.py at {time.strftime('%Y-%m-%d %H:%M')}_")
    lines.append("")

    # Count non-empty sections
    active_sections = [(name, items) for name, items in
                       ((s, sections[s]) for s in SECTION_ORDER) if items]

    if not active_sections:
        lines.append("_No traces found in Kudzu._")
        return "\n".join(lines)

    # Calculate per-section line budget (header = 2 lines each: ## + blank)
    header_overhead = 4  # top header lines already used
    section_overhead = len(active_sections) * 2  # ## heading + blank line per section
    available = LINE_BUDGET - header_overhead - section_overhead
    if available < len(active_sections):
        available = len(active_sections)

    # Distribute lines proportionally, minimum 1 per section
    total_items = sum(len(items) for _, items in active_sections)
    per_section = {}
    for name, items in active_sections:
        if total_items > 0:
            share = max(1, int(available * len(items) / total_items))
        else:
            share = 1
        per_section[name] = share

    # Adjust to not exceed budget
    while sum(per_section.values()) > available and any(v > 1 for v in per_section.values()):
        # Shrink the largest section
        largest = max(per_section, key=per_section.get)
        per_section[largest] -= 1

    # Render
    for name, items in active_sections:
        max_items = per_section.get(name, 3)
        lines.append(f"## {name}")
        lines.append("")
        for content, _ in items[:max_items]:
            bullet = truncate_line(content)
            lines.append(f"- {bullet}")
        lines.append("")

    # Final trim to budget
    if len(lines) > LINE_BUDGET:
        lines = lines[:LINE_BUDGET - 1]
        lines.append("_... (truncated to fit line budget)_")

    return "\n".join(lines)


def render_fallback_md(reason: str) -> str:
    """Render a minimal fallback MEMORY.md when Kudzu is unreachable."""
    return "\n".join([
        "# Kudzu Memory Context",
        "",
        f"_Auto-generated by kudzu-context.py at {time.strftime('%Y-%m-%d %H:%M')}_",
        "",
        f"**WARNING**: Kudzu is currently unreachable ({reason}).",
        "Context may be stale or unavailable. Try:",
        "```",
        'ssh titan "curl -s http://localhost:4000/health"',
        "```",
        "",
    ])


# ---------------------------------------------------------------------------
# Session trace recording
# ---------------------------------------------------------------------------

def record_context_run(memory_id: str) -> None:
    """Record a session_context trace to mark this context build."""
    if not memory_id:
        return
    try:
        import socket
        hostname = socket.gethostname()
        api_post(f"/api/v1/holograms/{memory_id}/traces", {
            "purpose": "session_context",
            "data": {
                "content": "Auto-context build for Claude Code session",
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "type": "context_build",
                "machine": hostname,
            },
        })
    except Exception:
        pass  # Non-critical; don't let recording failures block context build


# ---------------------------------------------------------------------------
# Summary output (for hook stdout)
# ---------------------------------------------------------------------------

def print_summary(sections: dict) -> None:
    """Print a compact summary to stdout for Claude Code hook injection."""
    active = [(name, items) for name in SECTION_ORDER
              if (items := sections.get(name, []))]
    if not active:
        print("[kudzu-context] No traces found")
        return

    total = sum(len(items) for _, items in active)
    section_names = ", ".join(name for name, _ in active)
    print(f"[kudzu-context] Loaded {total} traces into {len(active)} sections: {section_names}")

    # Show the top 3 most recent items across all sections
    all_items = []
    for name, items in active:
        for content, recency in items[:3]:
            all_items.append((name, content, recency))
    all_items.sort(key=lambda x: x[2], reverse=True)

    for name, content, _ in all_items[:3]:
        line = truncate_line(content, 90)
        print(f"  [{name}] {line}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <memory_md_path>", file=sys.stderr)
        sys.exit(1)

    memory_md_path = Path(sys.argv[1])

    # Ensure parent directory exists
    memory_md_path.parent.mkdir(parents=True, exist_ok=True)

    # Step 1: Check Kudzu health
    kudzu_reachable = False
    try:
        health = api_get("/health")
        if health.get("status") == "ok":
            kudzu_reachable = True
    except Exception as e:
        # Write fallback and exit gracefully
        memory_md_path.write_text(render_fallback_md(str(e)[:80]))
        print(f"[kudzu-context] Kudzu unreachable: {e}", file=sys.stderr)
        print("[kudzu-context] Wrote fallback MEMORY.md")
        return

    if not kudzu_reachable:
        memory_md_path.write_text(render_fallback_md("health check failed"))
        print("[kudzu-context] Kudzu health check failed", file=sys.stderr)
        print("[kudzu-context] Wrote fallback MEMORY.md")
        return

    # Step 2: Get hologram IDs
    ids = get_hologram_ids()
    memory_id = ids.get("MEMORY_ID", "")
    research_id = ids.get("RESEARCH_ID", "")
    learning_id = ids.get("LEARNING_ID", "")

    if not any([memory_id, research_id, learning_id]):
        memory_md_path.write_text(render_fallback_md("no holograms found"))
        print("[kudzu-context] No hologram IDs found", file=sys.stderr)
        print("[kudzu-context] Wrote fallback MEMORY.md")
        return

    # Step 3: Fetch traces from all holograms
    all_traces = []

    for hid in [memory_id, research_id, learning_id]:
        all_traces.extend(fetch_traces(hid))

    # Also fetch from project holograms
    for pid in get_project_hologram_ids():
        all_traces.extend(fetch_traces(pid, limit=20))

    # Step 4: Build sections
    sections = build_sections(all_traces)

    # Step 5: Render and write MEMORY.md
    md_content = render_memory_md(sections)
    memory_md_path.write_text(md_content)

    # Step 6: Record this context-build run
    record_context_run(memory_id)

    # Step 7: Print summary to stdout
    print_summary(sections)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        # Last-resort catch: write fallback and report error
        if len(sys.argv) >= 2:
            try:
                Path(sys.argv[1]).write_text(render_fallback_md(str(exc)[:80]))
            except OSError:
                pass
        print(f"[kudzu-context] Fatal error: {exc}", file=sys.stderr)
        sys.exit(1)
