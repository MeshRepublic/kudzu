"""Pure text formatting for the Proposals view (no Textual; unit-tested directly)."""
from __future__ import annotations

DASH = "—"
BANNER_TEXT = "Judge only — no distilled Constitution loaded"
GLYPHS = {"permitted": "✓", "denied": "✗", "denied_by_accumulation": "✗",
          "permitted_with_weight": "⚖", "cannot_evaluate": "?"}


def num(value, places: int = 2) -> str:
    """Format a number, or `—` when missing/not a number (never `0.00` for null)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return DASH
    return f"{value:.{places}f}"


def decision_of(proposal: dict) -> dict:
    d = proposal.get("decision")
    return d if isinstance(d, dict) else {}


def glyph(kind) -> str:
    return GLYPHS.get(kind, "?")


def headline(decision: dict) -> str:
    kind = decision.get("kind")
    if kind == "permitted":
        return "✓ PERMITTED"
    if kind == "denied":
        return "✗ DENIED"
    if kind == "denied_by_accumulation":
        return "✗ DENIED — accumulated weight"
    if kind == "permitted_with_weight":
        return f"⚖ PERMITTED WITH WEIGHT {num(decision.get('weight'))} — needs a vote"
    if kind == "cannot_evaluate":
        return "? CANNOT EVALUATE"
    return f"? {kind}"  # an unknown kind is shown as the backend sent it


def verdict_text(decision: dict) -> str:
    """Headline plus whatever reasons/citations the backend supplied, verbatim."""
    lines = [headline(decision)]
    if decision.get("kind") == "cannot_evaluate" and decision.get("reason"):
        lines.append(str(decision["reason"]))
    elif decision.get("reason"):
        lines.append(f"Reason: {decision['reason']}")
    if decision.get("citation"):
        lines.append(f"Citation: {decision['citation']}")
    if decision.get("principle"):
        lines.append(f"Principle: {decision['principle']}")
    if decision.get("reasoning"):
        lines.append(f"Reasoning: {decision['reasoning']}")
    evidence = decision.get("evidence")
    if isinstance(evidence, list) and evidence:
        lines.append("Evidence:")
        lines.extend(f"  - {item}" for item in evidence)
    return "\n".join(lines)


def _tally_summary(tally) -> str | None:
    if not isinstance(tally, dict):
        return None
    counts = {k: v for k, v in tally.items() if isinstance(v, int) and not isinstance(v, bool)}
    total = sum(counts.values())
    if total <= 0:
        return None
    top = max(counts.values())
    leaders = [k for k, v in counts.items() if v == top]
    return f"{top}/{total} {leaders[0] if len(leaders) == 1 else 'split'}"


def stage_detail(stage: dict) -> str:
    outcome = stage.get("outcome")
    if outcome == "not_reached":
        return DASH
    d = stage.get("detail")
    d = d if isinstance(d, dict) else {}
    n = stage.get("stage")
    if n == 1:
        if d.get("best_similarity") is None:
            return "no match"
        return f"best {num(d['best_similarity'])} vs τ_R {num(d.get('tau_r'))}"
    if n == 2:
        return f"weight {num(d.get('accumulated_weight'))} vs τ_A {num(d.get('tau_a'))}"
    if n == 3:
        if d.get("best_similarity") is None:
            return "no match"
        return f"best {num(d['best_similarity'])} vs {num(d.get('threshold'))}"
    if n == 4:
        if outcome == "error":
            return str(d.get("error") or DASH)
        conf = f"confidence {num(d.get('confidence'))}"
        summary = _tally_summary(d.get("tally"))
        return f"{summary} · {conf}" if summary else conf
    if n == 5:
        parts = [str(outcome)]
        if d.get("weight") is not None:
            parts.append(f"weight {num(d['weight'])}")
        if d.get("citation"):
            parts.append(str(d["citation"]))
        return " · ".join(parts)
    return DASH


def stage_row(stage: dict) -> str:
    return (f"{stage.get('stage', '?')}  {str(stage.get('name', '')):<24} "
            f"{str(stage.get('outcome', '')):<14} {stage_detail(stage)}")


def history_label(proposal: dict) -> str:
    text = " ".join(str(proposal.get("text", "")).split())[:40]
    return f"{glyph(decision_of(proposal).get('kind'))} {text}"


def vote_status(proposal: dict, accumulated) -> str:
    vote = proposal.get("vote")
    if vote not in ("yes", "no"):
        return ""
    return f"voted {vote} · accumulated {proposal.get('principle')}: {num(accumulated)}"


def evaluated_text(p: dict) -> str:
    """Heading of the verdict pane: the text and principle the server evaluated."""
    return f"Proposal: {p.get('text', '')}\nPrinciple: {p.get('principle', '')}"
