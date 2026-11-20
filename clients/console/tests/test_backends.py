import json

import pytest
import requests

from kudzu_console import backends, commands
from kudzu_console.backends import BACKENDS, Event, run_pipeline
from kudzu_console.config import Settings

SETTINGS = Settings(kudzu_host="http://k:1", kudzu_api_key="kkey", ollama_host="http://o:2",
                    searxng_host="http://s:3", anthropic_api_key="sk-test")


class Resp:
    def __init__(self, status=200, lines=(), json_data=None, text=""):
        self.status_code = status
        self._lines = list(lines)
        self._json = json_data
        self.text = text

    def iter_lines(self, decode_unicode=True):
        yield from self._lines

    def json(self):
        return self._json


def sse(*events):
    out = []
    for name, data in events:
        out += [f"event: {name}", f"data: {json.dumps(data)}", ""]
    return out


def claude_sse(*datas):
    return [f"data: {json.dumps(d)}" for d in datas]


class Net:
    """Records every request; routes by URL substring."""

    def __init__(self, monkeypatch):
        self.calls = []
        self.routes = {}
        monkeypatch.setattr(backends.requests, "post", lambda url, **kw: self._go("POST", url, kw))
        monkeypatch.setattr(backends.requests, "get", lambda url, **kw: self._go("GET", url, kw))

    def _go(self, method, url, kw):
        self.calls.append((method, url, kw))
        for part, handler in self.routes.items():
            if part in url:
                return handler(kw) if callable(handler) else handler
        raise AssertionError(f"unexpected request {method} {url}")

    def urls(self, part):
        return [c for c in self.calls if part in c[1]]


@pytest.fixture
def net(monkeypatch):
    n = Net(monkeypatch)
    n.routes["/brain/status"] = Resp(json_data={"hologram_id": "h1"})
    n.routes["/traces"] = Resp(json_data={})
    return n


def collect():
    events = []
    return events, events.append


def kudzu_ok(text="brain says hi", tier=2, cost=0.01):
    return Resp(lines=sse(("chunk", {"text": text}), ("done", {"tier": tier, "cost": cost})))


def ollama_ok(text="ollama says hi"):
    return Resp(lines=[json.dumps({"message": {"content": text}}), json.dumps({"done": True})])


def test_backend_list_order_and_defaults():
    assert [b.key for b in BACKENDS] == [
        "kudzu", "ollama:llama4:scout", "ollama:llama3.1:latest", "ollama:deepseek-r1:latest",
        "ollama:mistral:latest", "ollama:gemma3:latest", "ollama:qwen:latest", "web", "claude"]
    assert [b.key for b in BACKENDS if b.default_on] == ["kudzu"]


def test_order_respected_and_disabled_never_called(net):
    net.routes["/brain/chat"] = kudzu_ok()
    net.routes["/api/chat"] = ollama_ok()
    net.routes["/search"] = Resp(json_data={"results": []})
    order = []
    # enabled list order is irrelevant: pipeline order wins
    run_pipeline("q", ["web", "ollama:mistral:latest", "kudzu"], SETTINGS, lambda e: order.append(e.backend))
    hosts = [c[1] for c in net.calls if "/brain/chat" in c[1] or "/api/chat" in c[1] or "/search" in c[1]]
    assert hosts == ["http://k:1/api/v1/brain/chat", "http://o:2/api/chat", "http://s:3/search"]
    assert not net.urls("anthropic")


def test_context_from_stage1_reaches_stage2(net):
    net.routes["/brain/chat"] = kudzu_ok("PURPLE-ELEPHANT")
    net.routes["/api/chat"] = ollama_ok()
    run_pipeline("what?", ["kudzu", "ollama:qwen:latest"], SETTINGS, lambda e: None)
    sent = net.urls("/api/chat")[0][2]["json"]
    prompt = sent["messages"][0]["content"]
    assert sent["model"] == "qwen:latest"
    assert "Question: what?" in prompt and "[Kudzu Brain]:" in prompt and "PURPLE-ELEPHANT" in prompt


def test_connection_error_emits_one_error_and_pipeline_continues(net):
    def boom(kw):
        raise requests.ConnectionError("down")
    net.routes["/brain/chat"] = boom
    net.routes["/api/chat"] = ollama_ok("still here")
    events, on = collect()
    result = run_pipeline("q", ["kudzu", "ollama:qwen:latest"], SETTINGS, on)
    errors = [e for e in events if e.kind == "error"]
    assert len(errors) == 1 and errors[0].backend == "Kudzu Brain"
    assert any(e.kind == "chunk" and e.backend == "Ollama: qwen" and e.text == "still here" for e in events)
    assert result.tier is None


def test_unexpected_exception_is_contained(net):
    net.routes["/brain/chat"] = lambda kw: (_ for _ in ()).throw(ValueError("weird"))
    events, on = collect()
    run_pipeline("q", ["kudzu"], SETTINGS, on)
    assert [e.kind for e in events] == ["error"]


def test_result_carries_tier_and_cost(net):
    net.routes["/brain/chat"] = kudzu_ok(tier=2, cost=0.0)
    result = run_pipeline("q", ["kudzu"], SETTINGS, lambda e: None)
    assert (result.tier, result.cost_usd, result.tool_calls) == (2, 0.0, [])


def test_claude_request_body_and_headers(net):
    net.routes["anthropic"] = Resp(lines=claude_sse(
        {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "hi"}}))
    run_pipeline("q", ["claude"], SETTINGS, lambda e: None)
    _, url, kw = net.urls("anthropic")[0]
    body = kw["json"]
    assert body["model"] == "claude-opus-5-5"
    assert body["max_tokens"] == 16000
    for banned in ("temperature", "top_p", "top_k", "thinking"):
        assert banned not in body
    assert kw["headers"]["anthropic-version"] == "2023-06-01"


def test_claude_stream_ignores_thinking_and_signature(net):
    net.routes["anthropic"] = Resp(lines=claude_sse(
        {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "SECRET"}},
        {"type": "content_block_delta", "delta": {"type": "signature_delta", "signature": "sig"}},
        {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hel"}},
        {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "lo"}},
        {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}))
    events, on = collect()
    run_pipeline("q", ["claude"], SETTINGS, on)
    assert [(e.kind, e.text) for e in events] == [("chunk", "Hel"), ("chunk", "lo")]


def test_claude_non_stream_joins_text_blocks_only(net):
    net.routes["anthropic"] = Resp(json_data={"stop_reason": "end_turn", "content": [
        {"type": "thinking", "thinking": "SECRET"}, {"type": "text", "text": "A"},
        {"type": "text", "text": "B"}]})
    events, on = collect()
    ctx = {}
    out = backends.query_claude("q", ctx, SETTINGS, lambda k, t: on(Event("c", k, t)), stream=False)
    assert out == "AB"
    assert "stream" in net.urls("anthropic")[0][2]["json"]
    assert net.urls("anthropic")[0][2]["json"]["stream"] is False


@pytest.mark.parametrize("final", [
    {"type": "message_delta", "delta": {"stop_reason": "refusal"}},
])
def test_claude_refusal_emits_error(net, final):
    net.routes["anthropic"] = Resp(lines=claude_sse(final))
    events, on = collect()
    run_pipeline("q", ["claude"], SETTINGS, on)
    assert [(e.backend, e.kind, e.text) for e in events] == [("Claude API", "error", "Claude declined to answer")]


def test_claude_non_stream_refusal(net):
    net.routes["anthropic"] = Resp(json_data={"stop_reason": "refusal", "content": []})
    with pytest.raises(backends.BackendError, match="Claude declined to answer"):
        backends.query_claude("q", {}, SETTINGS, lambda k, t: None, stream=False)


def test_claude_without_key_makes_no_request(net):
    events, on = collect()
    run_pipeline("q", ["claude"], Settings(anthropic_api_key=""), on)
    assert [(e.kind, e.text) for e in events] == [("error", "ANTHROPIC_API_KEY not set")]
    assert not net.calls


def test_claude_http_error_does_not_leak_key(net):
    net.routes["anthropic"] = Resp(status=401, text="bad key")
    events, on = collect()
    run_pipeline("q", ["claude"], SETTINGS, on)
    assert events[0].kind == "error" and "sk-test" not in events[0].text


def test_knowledge_stored_when_more_than_brain_ran(net):
    net.routes["/brain/chat"] = kudzu_ok()
    net.routes["/search"] = Resp(json_data={"results": [{"title": "T", "content": "C"}]})
    run_pipeline("find it", ["kudzu", "web"], SETTINGS, lambda e: None)
    posts = [c for c in net.calls if c[0] == "POST" and "/holograms/h1/traces" in c[1]]
    assert len(posts) == 1
    data = posts[0][2]["json"]["data"]
    assert data["source"] == "chat_pipeline" and data["query"] == "find it"
    assert data["backends"] == ["Kudzu Brain", "Web"]
    assert "T: C" in data["summary"]


def test_knowledge_not_stored_for_brain_only(net):
    net.routes["/brain/chat"] = kudzu_ok()
    run_pipeline("q", ["kudzu"], SETTINGS, lambda e: None)
    assert not [c for c in net.calls if "/traces" in c[1]]


def test_web_results_become_chunks(net):
    net.routes["/search"] = Resp(json_data={"results": [{"title": "T1", "content": "C1"}]})
    events, on = collect()
    run_pipeline("q", ["web"], SETTINGS, on)
    assert events[0].kind == "status"
    assert "T1" in events[1].text and "C1" in events[1].text


def test_commands_status_progress_traces(net):
    net.routes["/brain/status"] = Resp(json_data={"state": "ok", "budget": {"calls": 3}, "hologram_id": "h1"})
    out = commands.run_command("status", SETTINGS)
    assert out.startswith("Brain Status:") and "  state: ok" in out and "    calls: 3" in out
    net.routes["/brain/chat"] = Resp(lines=sse(("chunk", {"text": "goal A"})))
    assert commands.run_command("progress", SETTINGS) == "[Kudzu Brain] goal A"
    net.routes["/traces"] = Resp(json_data=[
        {"timestamp": "2026-01-01T00:00:00.123", "purpose": "thought", "data": {"content": "hm"}}])
    out = commands.run_command("traces", SETTINGS, ["thought", "3"])
    assert out == "Recent traces:\n  2026-01-01T00:00:00 [thought] hm"
    assert net.urls("/traces")[-1][2]["params"] == {"limit": 3, "purpose": "thought"}


def test_command_errors_are_text_not_exceptions(net):
    def boom(kw):
        raise requests.ConnectionError("nope")
    net.routes["/brain/status"] = boom
    assert commands.run_command("status", SETTINGS).startswith("Status error:")
    assert commands.run_command("traces", SETTINGS).startswith("Traces error:")


def test_stage_prompt_matches_old_build_prompt_exactly(net):
    net.routes["/brain/chat"] = kudzu_ok("BRAIN")
    net.routes["/search"] = Resp(json_data={"results": [{"title": "T", "content": "C"}]})
    net.routes["anthropic"] = Resp(lines=[])
    run_pipeline("Q?", ["kudzu", "web", "claude"], SETTINGS, lambda e: None)
    prompt = net.urls("anthropic")[0][2]["json"]["messages"][0]["content"]
    # what the old _build_prompt produced for {"Kudzu Brain": ..., "Web": ...}
    assert prompt == ("Question: Q?\n\nContext from previous sources:\n\n[Kudzu Brain]:\nBRAIN"
                      "\n\n[Web]:\nT: C\n\nPlease answer the question using the above context where relevant.")


def test_claude_stage_sees_old_ollama_key(net):
    net.routes["/api/chat"] = ollama_ok("OL")
    net.routes["anthropic"] = Resp(lines=[])
    run_pipeline("Q", ["ollama:llama3.1:latest", "claude"], SETTINGS, lambda e: None)
    prompt = net.urls("anthropic")[0][2]["json"]["messages"][0]["content"]
    assert "\n[Ollama: llama3.1:latest]:\nOL" in prompt
