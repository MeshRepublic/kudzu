"""Multi-backend chat pipeline: Kudzu Brain -> Ollama model(s) -> Web (SearXNG) -> Claude API.

Pure Python (no Textual). Each stage receives the context accumulated by the earlier stages.
`run_pipeline` is called from a worker thread and reports progress through `on_event`.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Callable

import requests
from requests.exceptions import ChunkedEncodingError

CLAUDE_API = "https://api.anthropic.com/v1/messages"
CLAUDE_MODEL = "claude-opus-5-5"
CLAUDE_MAX_TOKENS = 16000
REFUSAL_TEXT = "Claude declined to answer"


@dataclass(frozen=True)
class Backend:
    key: str
    label: str
    default_on: bool = False


# Pipeline order. Ollama entries are the ones the old chat listed.
BACKENDS: list[Backend] = [
    Backend("kudzu", "Kudzu Brain", True),
    Backend("ollama:llama4:scout", "Ollama: llama4:scout"),
    Backend("ollama:llama3.1:latest", "Ollama: llama3.1"),
    Backend("ollama:deepseek-r1:latest", "Ollama: deepseek-r1"),
    Backend("ollama:mistral:latest", "Ollama: mistral"),
    Backend("ollama:gemma3:latest", "Ollama: gemma3"),
    Backend("ollama:qwen:latest", "Ollama: qwen"),
    Backend("web", "Web (SearXNG)"),
    Backend("claude", "Claude API"),
]


@dataclass(frozen=True)
class Event:
    backend: str  # human label, e.g. "Kudzu Brain"
    kind: str  # "status" | "chunk" | "error"
    text: str


@dataclass
class PipelineResult:
    tier: int | None = None
    tool_calls: list[str] = field(default_factory=list)
    cost_usd: float = 0.0


class BackendError(Exception):
    """A backend failed in a way worth showing to the user as-is."""


def label_for(key: str) -> str:
    for b in BACKENDS:
        if b.key == key:
            return b.label
    return f"Ollama: {key[7:]}" if key.startswith("ollama:") else key


def kudzu_headers(settings, *, json_body: bool = False) -> dict:
    headers = {"Content-Type": "application/json"} if json_body else {}
    if settings.kudzu_api_key:
        headers["Authorization"] = f"Bearer {settings.kudzu_api_key}"
    return headers


def safe_iter(resp):
    """Iterate lines, tolerating a connection closed mid-stream."""
    try:
        yield from resp.iter_lines(decode_unicode=True)
    except ChunkedEncodingError:
        pass


def build_prompt(message: str, context: dict[str, str]) -> str:
    """Enriched prompt with the output of earlier stages."""
    if not context:
        return message
    parts = [f"Question: {message}", "", "Context from previous sources:"]
    for source, text in context.items():
        if text and text.strip():
            parts.append(f"\n[{source}]:")
            parts.append(text.strip()[:2000])
    parts.append("\nPlease answer the question using the above context where relevant.")
    return "\n".join(parts)


# --- Kudzu Brain ---------------------------------------------------------------------

def query_kudzu(message: str, settings, emit: Callable[[str, str], None], result: PipelineResult) -> str:
    """Stream /brain/chat SSE. `emit(kind, text)`; updates tier/cost/tool_calls on `result`."""
    try:
        resp = requests.post(
            f"{settings.kudzu_host}/api/v1/brain/chat",
            headers=kudzu_headers(settings, json_body=True),
            json={"message": message}, stream=True, timeout=120)
    except requests.exceptions.ConnectionError:
        raise BackendError("Connection failed. Is Kudzu Brain running?") from None
    if resp.status_code == 401:
        raise BackendError("Auth failed. Check KUDZU_API_KEY.")
    if resp.status_code != 200:
        raise BackendError(f"HTTP {resp.status_code}")

    accumulated = ""
    event_type = ""
    for line in safe_iter(resp):
        if not line:
            continue
        if line.startswith("event: "):
            event_type = line[7:]
            continue
        if not line.startswith("data: "):
            continue
        try:
            data = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        if not isinstance(data, dict):
            continue
        if event_type == "thinking":
            emit("status", f"({data.get('status', '')})")
        elif event_type == "chunk":
            text = data.get("text", "")
            accumulated += text
            emit("chunk", text)
        elif event_type in ("tool_call", "tool_use", "tool"):
            result.tool_calls.append(str(data.get("name", data.get("tool", "?"))))
        elif event_type == "done":
            tier = data.get("tier")
            cost = data.get("cost", 0.0)
            if isinstance(tier, int):
                result.tier = tier
            if isinstance(cost, (int, float)):
                result.cost_usd += float(cost)
            emit("status", f"[tier {tier if tier is not None else '?'}, ${float(cost or 0):.4f}]")
        elif event_type == "error":
            emit("error", str(data.get("error", "unknown")))
    return accumulated


# --- Ollama ---------------------------------------------------------------------------

def query_ollama(message: str, model: str, context: dict[str, str], settings,
                 emit: Callable[[str, str], None]) -> str:
    try:
        resp = requests.post(
            f"{settings.ollama_host}/api/chat",
            json={"model": model, "messages": [{"role": "user", "content": build_prompt(message, context)}],
                  "stream": True},
            stream=True, timeout=600)  # large models take time to load
    except requests.exceptions.ConnectionError:
        raise BackendError("Ollama not available.") from None
    if resp.status_code != 200:
        raise BackendError(f"HTTP {resp.status_code}")
    accumulated = ""
    for line in resp.iter_lines(decode_unicode=True):
        if not line:
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        chunk = data.get("message", {}).get("content", "")
        if chunk:
            accumulated += chunk
            emit("chunk", chunk)
        if data.get("done"):
            break
    return accumulated


# --- Web (SearXNG) --------------------------------------------------------------------

def query_web(message: str, settings, emit: Callable[[str, str], None]) -> str:
    emit("status", "Searching...")
    try:
        resp = requests.get(f"{settings.searxng_host}/search",
                            params={"q": message, "format": "json"}, timeout=15)
    except requests.exceptions.ConnectionError:
        raise BackendError("SearXNG not available (port 8888).") from None
    if resp.status_code != 200:
        raise BackendError(f"Search error: HTTP {resp.status_code}")
    results = resp.json().get("results", [])[:5]
    if not results:
        emit("status", "No results found.")
        return ""
    lines = []
    for r in results:
        title, snippet = r.get("title", ""), r.get("content", "")
        lines.append(f"  {title}: {snippet}")
        emit("chunk", f"**{title}**\n\n{snippet}\n\n")
    return "\n".join(lines)


# --- Claude API -----------------------------------------------------------------------

def query_claude(message: str, context: dict[str, str], settings, emit: Callable[[str, str], None],
                 *, stream: bool = True) -> str:
    if not settings.anthropic_api_key:
        raise BackendError("ANTHROPIC_API_KEY not set")
    # No temperature/top_p/top_k and no `thinking` field: the current model rejects the former.
    body = {"model": CLAUDE_MODEL, "max_tokens": CLAUDE_MAX_TOKENS,
            "messages": [{"role": "user", "content": build_prompt(message, context)}],
            "stream": stream}
    try:
        resp = requests.post(
            CLAUDE_API,
            headers={"x-api-key": settings.anthropic_api_key, "anthropic-version": "2023-06-01",
                     "content-type": "application/json"},
            json=body, stream=stream, timeout=120)
    except requests.exceptions.ConnectionError:
        raise BackendError("Cannot reach Claude API.") from None
    if resp.status_code != 200:
        raise BackendError(f"HTTP {resp.status_code}: {resp.text[:200]}")

    accumulated = ""
    stop_reason = None
    if not stream:
        data = resp.json()
        stop_reason = data.get("stop_reason")
        accumulated = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
        if accumulated:
            emit("chunk", accumulated)
    else:
        for line in resp.iter_lines(decode_unicode=True):
            if not line or not line.startswith("data: "):
                continue
            raw = line[6:]
            if raw == "[DONE]":
                break
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                continue
            kind = data.get("type")
            if kind == "content_block_delta":
                delta = data.get("delta", {})
                if delta.get("type") == "text_delta" and delta.get("text"):
                    accumulated += delta["text"]
                    emit("chunk", delta["text"])
            elif kind == "message_delta":
                stop_reason = data.get("delta", {}).get("stop_reason") or stop_reason
            elif kind == "message_start":
                stop_reason = data.get("message", {}).get("stop_reason") or stop_reason
    if stop_reason == "refusal":
        raise BackendError(REFUSAL_TEXT)
    return accumulated


# --- Knowledge storage ----------------------------------------------------------------

def store_knowledge(message: str, context: dict[str, str], settings) -> None:
    """Send accumulated pipeline knowledge to Kudzu Brain as a trace (best effort)."""
    try:
        headers = kudzu_headers(settings)
        resp = requests.get(f"{settings.kudzu_host}/api/v1/brain/status", headers=headers, timeout=5)
        if resp.status_code != 200:
            return
        holo_id = resp.json().get("hologram_id")
        if not holo_id:
            return
        summary = "\n".join(f"[{k}]: {v[:500]}" for k, v in context.items() if v)
        requests.post(
            f"{settings.kudzu_host}/api/v1/holograms/{holo_id}/traces",
            json={"purpose": "discovery",
                  "data": {"source": "chat_pipeline", "query": message[:200],
                           "summary": summary[:3000], "backends": list(context.keys())}},
            headers=headers, timeout=5)
    except Exception:
        pass


# --- Pipeline -------------------------------------------------------------------------

def run_pipeline(message: str, enabled: list[str], settings,
                 on_event: Callable[[Event], None]) -> PipelineResult:
    """Run the enabled backends in pipeline order, each seeing the accumulated context."""
    result = PipelineResult()
    context: dict[str, str] = {}
    for backend in BACKENDS:
        if backend.key not in enabled:
            continue
        label = backend.label

        def emit(kind: str, text: str, _label: str = label) -> None:
            on_event(Event(_label, kind, text))

        try:
            if backend.key == "kudzu":
                text = query_kudzu(message, settings, emit, result)
            elif backend.key.startswith("ollama:"):
                text = query_ollama(message, backend.key[7:], context, settings, emit)
            elif backend.key == "web":
                text = query_web(message, settings, emit)
            else:
                text = query_claude(message, context, settings, emit)
        except BackendError as exc:
            emit("error", str(exc))
            continue
        except Exception as exc:  # a failing backend never stops the pipeline
            emit("error", f"{type(exc).__name__}: {exc}")
            continue
        if text:
            context[label] = text
    if len(context) > 1 or (context and "Kudzu Brain" not in context):
        store_knowledge(message, context, settings)
    return result
