"""Pure validation and result formatting for the Antitrust view (no Textual; unit-tested directly)."""
from __future__ import annotations

import math

DEFAULT_SHARE = 40
DEFAULT_DROP = 10
HEADLINES = {"triggered": "⚠ TRIGGERED — open-source methods",
             "watch": "◐ WATCH — one metric met",
             "not_triggered": "✓ NOT TRIGGERED"}
TRIGGERED_NOTE = "Both metrics met (white paper §6.2). Company keeps its brand."
# server 422 field name -> widget id (anything else is a general error)
FIELD_IDS = {"market_share": "share", "baseline_satisfaction": "baseline", "current_satisfaction": "current",
             "share": "th-share", "satisfaction_drop": "th-drop"}


def parse_number(text: str) -> float | None:
    try:
        value = float(text.strip())
    except (ValueError, AttributeError):
        return None
    return value if math.isfinite(value) else None


def num(value) -> str:
    """Number as the server sent it; whole floats lose the trailing `.0`."""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def validate(values: dict[str, str]) -> tuple[dict | None, dict[str, str]]:
    """values: widget id -> text. Returns (request body, {}) or (None, {widget id: message})."""
    errors: dict[str, str] = {}
    nums: dict[str, float] = {}
    for fid in ("share", "baseline", "current", "th-share", "th-drop"):
        n = parse_number(values.get(fid, ""))
        if n is None:
            errors[fid] = "not a number"
        elif n < 0:
            errors[fid] = "must not be negative"
        elif fid == "share" and n > 100:
            errors[fid] = "must be at most 100"
        elif fid == "baseline" and n <= 0:
            errors[fid] = "must be above 0"
        else:
            nums[fid] = n
    if errors:
        return None, errors
    body: dict = {"market_share": nums["share"], "baseline_satisfaction": nums["baseline"],
                  "current_satisfaction": nums["current"],
                  "thresholds": {"share": nums["th-share"], "satisfaction_drop": nums["th-drop"]}}
    for key, fid in (("company", "company"), ("vertical", "vertical")):
        text = values.get(fid, "").strip()
        if text:
            body[key] = text
    return body, {}


def _mark(met) -> str:
    return "✓" if met else "✗"


def _drop(pct) -> str:
    if isinstance(pct, (int, float)) and not isinstance(pct, bool):
        if pct > 0:
            return f"−{pct:.2f}"
        if pct < 0:
            return f"+{-pct:.2f}"
        return f"{pct:.2f}"
    return "—"


def result_text(resp: dict) -> str | None:
    """Result panel text from a server response, or None when the response is not usable."""
    try:
        kind = resp["result"]
        c, s = resp["concentration"], resp["satisfaction"]
        if kind not in HEADLINES:
            return None
        op = "≥" if c["met"] else "<"
        lines = [HEADLINES[kind],
                 f"Concentration  {num(c['share'])}% {op} {num(c['threshold'])}%  {_mark(c['met'])}",
                 f"Satisfaction   {num(s['baseline'])} → {num(s['current'])}  {_drop(s['drop_pct'])}%  {_mark(s['met'])}",
                 f"               (limit −{num(s['threshold'])}%)"]
    except (KeyError, TypeError):
        return None
    if kind == "triggered":
        lines.append(TRIGGERED_NOTE)
    return "\n".join(lines)
