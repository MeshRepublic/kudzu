"""Pure sorting, filtering and formatting for the Ledger view (no Textual; unit-tested directly)."""
from __future__ import annotations

from datetime import datetime, timezone

EMPTY_TEXT = "No ratified weights yet."
# (key, header label), in display order
COLUMNS = [("time", "time"), ("principle", "principle"), ("weight", "weight"),
           ("proposal", "proposal id"), ("anchor", "anchor status")]
ARROWS = {False: "▲", True: "▼"}  # keyed by descending


def columns(narrow: bool) -> list[tuple[str, str]]:
    """Narrow layouts drop the proposal id column."""
    return [c for c in COLUMNS if not (narrow and c[0] == "proposal")]


def parse_time(raw) -> datetime | None:
    try:
        text = str(raw).strip()
        if text.endswith(("Z", "z")):
            text = text[:-1] + "+00:00"
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    return dt.astimezone(timezone.utc) if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def fmt_time(raw) -> str:
    """`YYYY-MM-DD HH:MM:SS` in UTC; the raw string when it cannot be parsed."""
    dt = parse_time(raw)
    return dt.strftime("%Y-%m-%d %H:%M:%S") if dt else str(raw)


def fmt_weight(value) -> str:
    return f"{float(value):.2f}"


def total_label(principle: str, total: float, tau_a: float) -> str:
    return f"{principle}  {float(total):.2f} / {float(tau_a):.2f}"


def is_over(total: float, tau_a: float) -> bool:
    return float(total) > float(tau_a)


def header_label(key: str, label: str, sort_key: str | None, descending: bool) -> str:
    return f"{label} {ARROWS[descending]}" if key == sort_key else label


def cell_text(entry: dict, key: str) -> str:
    if key == "time":
        return fmt_time(entry["recorded_at"])
    if key == "weight":
        return fmt_weight(entry["weight"])
    return str(entry[{"principle": "principle", "proposal": "proposal_id", "anchor": "anchor_status"}[key]])


def filter_entries(entries: list[dict], principle: str | None) -> list[dict]:
    return list(entries) if principle is None else [e for e in entries if e["principle"] == principle]


def _sort_value(entry: dict, key: str):
    if key == "weight":
        return float(entry["weight"])
    if key == "time":
        dt = parse_time(entry["recorded_at"])
        # unparseable times sort after every real time
        return (dt is None, dt.timestamp() if dt else 0.0, str(entry["recorded_at"]))
    return cell_text(entry, key)


def sort_entries(entries: list[dict], key: str | None, descending: bool = False) -> list[dict]:
    """Server order when `key` is None. Stable in both directions."""
    if key is None:
        return list(entries)
    return sorted(entries, key=lambda e: _sort_value(e, key), reverse=descending)


def column_widths(entries: list[dict], cols: list[tuple[str, str]]) -> dict[str, int]:
    """Width per column: widest cell, or the label plus room for the sort arrow."""
    return {key: max([len(label) + 2] + [len(cell_text(e, key)) for e in entries]) for key, label in cols}


def row_text(entry: dict, cols: list[tuple[str, str]], widths: dict[str, int]) -> str:
    cells = []
    for key, _ in cols:
        text = cell_text(entry, key)
        cells.append(text.rjust(widths[key]) if key == "weight" else text.ljust(widths[key]))
    return "  ".join(cells).rstrip()


def parse_ledger(data) -> tuple[list[dict], dict[str, float], float] | None:
    """Validate a server response; None when it is not shaped as the contract says."""
    try:
        entries = data["entries"]
        totals = {str(k): float(v) for k, v in data["totals"].items()}
        tau = float(data["tau_a"])
        if not isinstance(entries, list):
            return None
        for e in entries:
            float(e["weight"])
            for k in ("proposal_id", "principle", "anchor_status", "recorded_at"):
                e[k]
            if not isinstance(e, dict):
                return None
    except (KeyError, TypeError, ValueError, AttributeError):
        return None
    return entries, totals, tau
