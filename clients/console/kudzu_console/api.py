"""REST client for the Kudzu API."""
from __future__ import annotations

from typing import Any
from urllib.parse import quote

import requests

from .config import Settings

TIMEOUT = (10, 120)  # connect, read seconds
EVALUATE_TIMEOUT = (10, 300)  # a judged evaluation; matches the server's 300 s idle timeout


class KudzuAPIError(Exception):
    def __init__(self, status: int | None, code: str, detail: dict | None = None):
        self.status = status
        self.code = code
        self.detail = detail if detail is not None else {}
        super().__init__(f"{code} (status={status})")


class KudzuAPI:
    def __init__(self, settings: Settings, session: Any = None):
        self._settings = settings
        self._session = session if session is not None else requests.Session()

    def _call(self, method: str, path: str, body: dict | None = None, *, auth: bool = True,
              prefix: str = "/api/v1", timeout: tuple[float, float] | None = None) -> dict:
        url = f"{self._settings.kudzu_host}{prefix}{path}"
        headers = {"Accept": "application/json"}
        if auth:
            headers["Authorization"] = f"Bearer {self._settings.kudzu_api_key}"
        kwargs: dict[str, Any] = {"headers": headers, "timeout": timeout or TIMEOUT}
        if body is not None:
            kwargs["json"] = body
        try:
            resp = self._session.request(method, url, **kwargs)
        except (requests.ConnectionError, requests.Timeout) as exc:
            raise KudzuAPIError(None, "unreachable", {"message": type(exc).__name__}) from None
        except requests.RequestException as exc:
            raise KudzuAPIError(None, "unreachable", {"message": type(exc).__name__}) from None

        try:
            data = resp.json()
        except ValueError:
            data = None

        if 200 <= resp.status_code < 300:
            if isinstance(data, dict):
                return data
            raise KudzuAPIError(resp.status_code, "server_error", {})
        if isinstance(data, dict):
            code = str(data.get("error", "server_error" if resp.status_code >= 500 else "http_error"))
            raise KudzuAPIError(resp.status_code, code, data)
        code = "server_error" if resp.status_code >= 500 else "http_error"
        raise KudzuAPIError(resp.status_code, code, {})

    def health(self, timeout: tuple[float, float] | None = None) -> dict:
        return self._call("GET", "/health", auth=False, prefix="", timeout=timeout)

    def governance_status(self, timeout: tuple[float, float] | None = None) -> dict:
        return self._call("GET", "/governance/status", timeout=timeout)

    def evaluate_proposal(self, text: str, principle: str) -> dict:
        return self._call("POST", "/governance/proposals/evaluate", {"text": text, "principle": principle},
                          timeout=EVALUATE_TIMEOUT)

    def vote(self, proposal_id: str, vote: str) -> dict:
        if str(proposal_id) in ("", ".", ".."):
            raise KudzuAPIError(None, "invalid_id", {})
        return self._call("POST", f"/governance/proposals/{quote(str(proposal_id), safe='')}/vote", {"vote": vote})

    def ledger(self) -> dict:
        return self._call("GET", "/governance/ledger")

    def evaluate_antitrust(self, scenario: dict) -> dict:
        return self._call("POST", "/governance/antitrust/evaluate", scenario)

    def brain_status(self) -> dict:
        return self._call("GET", "/brain/status")
