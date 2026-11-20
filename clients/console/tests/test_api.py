import pytest
import requests

from kudzu_console.api import KudzuAPI, KudzuAPIError
from kudzu_console.config import Settings


class StubResponse:
    def __init__(self, status_code=200, body=None, text=None):
        self.status_code = status_code
        self._body = body
        self.text = text if text is not None else ""

    @property
    def ok(self):
        return 200 <= self.status_code < 300

    def json(self):
        if self._body is None:
            raise ValueError("no json")
        return self._body


class StubSession:
    def __init__(self, response=None, exc=None):
        self.response = response or StubResponse(body={"ok": True})
        self.exc = exc
        self.calls = []

    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        if self.exc:
            raise self.exc
        return self.response


def make(response=None, exc=None):
    settings = Settings(
        kudzu_host="http://k:4001", kudzu_api_key="sekret",
        ollama_host="o", searxng_host="s", anthropic_api_key="",
    )
    session = StubSession(response, exc)
    return KudzuAPI(settings, session=session), session


def test_settings_defaults(monkeypatch):
    for k in ("KUDZU_HOST", "KUDZU_API_KEY", "OLLAMA_HOST", "SEARXNG_HOST", "ANTHROPIC_API_KEY"):
        monkeypatch.delenv(k, raising=False)
    s = Settings.from_env()
    assert s.kudzu_host == "http://100.70.67.110:4001"
    assert s.ollama_host == "http://localhost:11434"
    assert s.searxng_host == "http://localhost:8888"
    assert s.kudzu_api_key == "" and s.anthropic_api_key == ""


def test_settings_from_env(monkeypatch):
    monkeypatch.setenv("KUDZU_HOST", "http://x:1/")
    monkeypatch.setenv("KUDZU_API_KEY", "k")
    s = Settings.from_env()
    assert s.kudzu_host == "http://x:1"
    assert s.kudzu_api_key == "k"


@pytest.mark.parametrize("method,args,verb,path,body", [
    ("governance_status", (), "GET", "/api/v1/governance/status", None),
    ("evaluate_proposal", ("t", "p"), "POST", "/api/v1/governance/proposals/evaluate", {"text": "t", "principle": "p"}),
    ("vote", ("abc", "yes"), "POST", "/api/v1/governance/proposals/abc/vote", {"vote": "yes"}),
    ("ledger", (), "GET", "/api/v1/governance/ledger", None),
    ("evaluate_antitrust", ({"market_share": 0.5},), "POST", "/api/v1/governance/antitrust/evaluate", {"market_share": 0.5}),
    ("brain_status", (), "GET", "/api/v1/brain/status", None),
])
def test_endpoints(method, args, verb, path, body):
    api, session = make()
    assert getattr(api, method)(*args) == {"ok": True}
    m, url, kw = session.calls[0]
    assert m == verb
    assert url == "http://k:4001" + path
    assert kw["headers"]["Authorization"] == "Bearer sekret"
    assert kw["timeout"] == (10, 120)
    assert kw.get("json") == body


def test_health_path_has_no_prefix():
    api, session = make()
    api.health()
    assert session.calls[0][0] == "GET"
    assert session.calls[0][1] == "http://k:4001/health"


def test_422_raises_with_code():
    body = {"error": "unknown_principle", "principles": ["a"]}
    api, _ = make(StubResponse(422, body))
    with pytest.raises(KudzuAPIError) as e:
        api.evaluate_proposal("t", "zzz")
    assert e.value.status == 422
    assert e.value.code == "unknown_principle"
    assert e.value.detail == body


@pytest.mark.parametrize("exc", [requests.ConnectionError("boom"), requests.Timeout("slow")])
def test_unreachable(exc):
    api, _ = make(exc=exc)
    with pytest.raises(KudzuAPIError) as e:
        api.ledger()
    assert e.value.status is None
    assert e.value.code == "unreachable"


def test_500_html_body():
    api, _ = make(StubResponse(500, text="<html>oops</html>"))
    with pytest.raises(KudzuAPIError) as e:
        api.ledger()
    assert e.value.status == 500
    assert e.value.code == "server_error"


def test_non_json_4xx():
    api, _ = make(StubResponse(404, text="nope"))
    with pytest.raises(KudzuAPIError) as e:
        api.ledger()
    assert e.value.code == "http_error"


def test_2xx_non_json_raises_server_error():
    api, _ = make(StubResponse(200, text="<html>"))
    with pytest.raises(KudzuAPIError) as e:
        api.ledger()
    assert e.value.code == "server_error"


def test_error_does_not_leak_key():
    api, _ = make(StubResponse(401, {"error": "unauthorized"}))
    with pytest.raises(KudzuAPIError) as e:
        api.ledger()
    assert "sekret" not in str(e.value) and "sekret" not in repr(e.value)


@pytest.mark.parametrize("pid,encoded", [
    ("a/b?c", "a%2Fb%3Fc"),
    ("../x", "..%2Fx"),
    ("0123456789abcdef", "0123456789abcdef"),
])
def test_vote_path_encodes_proposal_id(pid, encoded):
    api, session = make()
    api.vote(pid, "yes")
    assert session.calls[0][1] == f"http://k:4001/api/v1/governance/proposals/{encoded}/vote"


@pytest.mark.parametrize("pid", ["", ".", ".."])
def test_vote_rejects_empty_and_dot_segment_ids(pid):
    api, session = make()
    with pytest.raises(KudzuAPIError) as e:
        api.vote(pid, "yes")
    assert e.value.status is None
    assert e.value.code == "invalid_id"
    assert session.calls == []
