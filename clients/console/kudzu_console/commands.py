"""Chat commands ported from the old /status, /progress and /traces handlers.

Each function returns the text to print into the conversation. Blocking HTTP: call from a worker.
"""
from __future__ import annotations

import requests

from .backends import PipelineResult, kudzu_headers, query_kudzu


def show_status(settings) -> str:
    try:
        resp = requests.get(f"{settings.kudzu_host}/api/v1/brain/status",
                            headers=kudzu_headers(settings), timeout=5)
        if resp.status_code != 200:
            return f"Status error: HTTP {resp.status_code}"
        lines = ["Brain Status:"]
        for k, v in resp.json().items():
            if isinstance(v, dict):
                lines.append(f"  {k}:")
                lines.extend(f"    {k2}: {v2}" for k2, v2 in v.items())
            else:
                lines.append(f"  {k}: {v}")
        return "\n".join(lines)
    except Exception as exc:
        return f"Status error: {exc}"


def show_progress(settings) -> str:
    parts: list[str] = []
    errors: list[str] = []

    def emit(kind: str, text: str) -> None:
        if kind == "chunk":
            parts.append(text)
        elif kind == "error":
            errors.append(text)

    try:
        query_kudzu("progress", settings, emit, PipelineResult())
    except Exception as exc:
        errors.append(str(exc))
    text = "".join(parts) + "".join(f"Error: {e}" for e in errors)
    return f"[Kudzu Brain] {text}"


def show_traces(settings, purpose: str | None = None, limit: int = 5) -> str:
    try:
        headers = kudzu_headers(settings)
        resp = requests.get(f"{settings.kudzu_host}/api/v1/brain/status", headers=headers, timeout=5)
        holo_id = resp.json().get("hologram_id")
        if not holo_id:
            return "Could not get hologram ID."
        params: dict = {"limit": limit}
        if purpose:
            params["purpose"] = purpose
        resp = requests.get(f"{settings.kudzu_host}/api/v1/holograms/{holo_id}/traces",
                            params=params, headers=headers, timeout=10)
        lines = ["Recent traces:"]
        for t in resp.json()[:limit]:
            ts = t.get("timestamp", "?")[:19]
            data = t.get("data", {})
            summary = str(data.get("content", data.get("summary", str(data))))[:100]
            lines.append(f"  {ts} [{t.get('purpose', '?')}] {summary}")
        return "\n".join(lines)
    except Exception as exc:
        return f"Traces error: {exc}"


def run_command(name: str, settings, args: list[str] | None = None) -> str:
    """Dispatch status / progress / traces; `args` are the words after the command."""
    args = args or []
    if name == "status":
        return show_status(settings)
    if name == "progress":
        return show_progress(settings)
    if name == "traces":
        purpose = args[0] if args else None
        try:
            limit = int(args[1]) if len(args) > 1 else 5
        except ValueError:
            limit = 5
        return show_traces(settings, purpose, limit)
    return f"Unknown command: {name}"
