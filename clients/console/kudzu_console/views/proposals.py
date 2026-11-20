"""Proposals view: evaluate a proposed law against a principle, show the five stages, vote."""
from __future__ import annotations

from textual import events
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Button, Label, ListItem, ListView, Select, Static, TextArea

from ..api import KudzuAPIError
from ..background import run_in_background
from .chat import ChatInput
from .proposals_format import (BANNER_TEXT, decision_of, evaluated_text, history_label,
                               stage_row, verdict_text, vote_status)

HISTORY_MIN_WIDTH = 140
TERMINAL_VOTE_ERRORS = ("already_voted", "not_found", "not_votable", "invalid_vote")
EVALUATE_LABEL = "Evaluate"
EVALUATING_LABEL = "evaluating…"


class PrinciplesLoaded(Message):
    def __init__(self, principles: list[str] | None) -> None:
        super().__init__()
        self.principles = principles


class ProposalEvaluated(Message):
    def __init__(self, seq: int, proposal: dict | None, error: str | None) -> None:
        super().__init__()
        self.seq = seq
        self.proposal = proposal
        self.error = error


class VoteCast(Message):
    def __init__(self, proposal_id: str, proposal: dict | None, accumulated, error: KudzuAPIError | None) -> None:
        super().__init__()
        self.proposal_id = proposal_id
        self.proposal = proposal
        self.accumulated = accumulated
        self.error = error


class HistoryItem(ListItem):
    def __init__(self, proposal_id: str, label: str) -> None:
        super().__init__(Label(label, markup=False))
        self.proposal_id = proposal_id


class ProposalsView(Widget):
    def __init__(self, api, settings) -> None:
        super().__init__(id="view-proposals")
        self.api = api
        self.settings = settings
        self._principles: list[str] = []
        self._loading = False
        self._busy = False  # an evaluation is in flight
        self._eval_seq = 0
        self._voting = False
        self._current: dict | None = None  # proposal on display
        self._session: dict[str, dict] = {}  # id -> proposal, this session only
        self._accumulated: dict[str, float] = {}
        self._vote_closed: dict[str, str] = {}  # id -> inline status of a terminal vote failure

    def compose(self) -> ComposeResult:
        with Horizontal(id="proposals-body"):
            with VerticalScroll(id="proposals-main"):
                # multi-line: pasted newlines are kept; Enter evaluates, Shift+Enter / Ctrl+J add a line
                yield ChatInput(id="proposal-input", placeholder="Proposed law…")
                yield Select([], prompt="Constitutional principle", id="principle-select")
                yield Button(EVALUATE_LABEL, id="evaluate", disabled=True)
                yield Static("", id="message", markup=False)
                yield Static("", id="evaluated", markup=False)
                yield Static(BANNER_TEXT, id="banner", markup=False)
                yield Static("", id="verdict", markup=False)
                with Vertical(id="stages"):
                    for n in range(1, 6):
                        yield Static("", id=f"stage-{n}", classes="stage-row", markup=False)
                with Horizontal(id="vote-row"):
                    yield Button("Vote yes", id="vote-yes", disabled=True)
                    yield Button("Vote no", id="vote-no", disabled=True)
                yield Static("", id="vote-status", markup=False)
            yield ListView(id="history")

    def on_mount(self) -> None:
        self.query_one("#banner").display = False
        self._apply_history_width()

    def on_show(self, event: events.Show) -> None:
        if not self._principles:
            self._load_principles()  # first show loads; a later show retries a failed load

    def on_resize(self, event: events.Resize) -> None:
        self._apply_history_width()

    def _apply_history_width(self) -> None:
        self.query_one("#history").display = self.app.size.width >= HISTORY_MIN_WIDTH

    def _post(self, message: Message) -> None:
        try:
            self.post_message(message)  # thread-safe; dropped if the app is going away
        except Exception:
            pass

    # --- principles -------------------------------------------------------
    def _load_principles(self) -> None:
        if self._loading:
            return
        self._loading = True
        run_in_background(self, self._principles_worker, name="kudzu-principles")

    def _principles_worker(self) -> None:
        try:
            names = [str(p) for p in self.api.governance_status()["principles"]]
        except Exception:
            names = None
        self._post(PrinciplesLoaded(names))

    def on_principles_loaded(self, message: PrinciplesLoaded) -> None:
        self._loading = False
        select = self.query_one("#principle-select", Select)
        if message.principles:
            self._principles = message.principles
            select.set_options([(p, p) for p in self._principles])
            self._set_message("")
        else:
            self._principles = []
            select.set_options([])
            self._set_message("✗ principles could not be loaded; they will be retried when this view is shown")
        self._refresh_evaluate()

    # --- evaluate ---------------------------------------------------------
    def _valid(self) -> bool:
        select = self.query_one("#principle-select", Select)
        return (bool(self.query_one("#proposal-input", TextArea).text.strip())
                and not select.is_blank() and select.value in self._principles)

    def _refresh_evaluate(self) -> None:
        self.query_one("#evaluate", Button).disabled = self._busy or not self._valid()

    def on_text_area_changed(self, event: TextArea.Changed) -> None:
        self._refresh_evaluate()

    def on_select_changed(self, event: Select.Changed) -> None:
        self._refresh_evaluate()

    def on_chat_input_submitted(self, event: ChatInput.Submitted) -> None:
        event.stop()
        self._start_evaluate()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        event.stop()
        if event.button.id == "evaluate":
            self._start_evaluate()
        elif event.button.id in ("vote-yes", "vote-no"):
            self._start_vote("yes" if event.button.id == "vote-yes" else "no")

    def _start_evaluate(self) -> None:
        if self._busy or not self._valid():
            return
        text = self.query_one("#proposal-input", TextArea).text.strip()
        principle = str(self.query_one("#principle-select", Select).value)
        self._busy = True
        self._eval_seq += 1
        self._clear_display()
        button = self.query_one("#evaluate", Button)
        button.label = EVALUATING_LABEL
        button.disabled = True
        seq = self._eval_seq
        run_in_background(self, lambda: self._evaluate_worker(seq, text, principle), name="kudzu-evaluate")

    def _evaluate_worker(self, seq: int, text: str, principle: str) -> None:
        proposal = error = None
        try:
            proposal = self.api.evaluate_proposal(text, principle)["proposal"]
            if not isinstance(proposal, dict):
                raise TypeError("proposal is not an object")
        except KudzuAPIError as exc:
            error = "server unreachable" if exc.code == "unreachable" else exc.code
        except Exception:
            error = "bad_response"
        if seq != self._eval_seq:
            return  # superseded; on_proposal_evaluated would drop it anyway
        self._post(ProposalEvaluated(seq, proposal, error))

    async def on_proposal_evaluated(self, message: ProposalEvaluated) -> None:
        if message.seq != self._eval_seq:
            return
        self._busy = False
        self.query_one("#evaluate", Button).label = EVALUATE_LABEL
        self._refresh_evaluate()
        if message.proposal is None:
            if message.error == "text_too_long":
                self._set_message("✗ proposal too long (20,000 characters max)")
            else:
                self._set_message(f"✗ evaluation failed: {message.error}")
            return
        p = message.proposal
        self._session[str(p.get("id"))] = p
        await self.query_one("#history", ListView).insert(
            0, [HistoryItem(str(p.get("id")), history_label(p))])
        self._show(p)

    # --- display ----------------------------------------------------------
    def _set_message(self, text: str) -> None:
        self.query_one("#message", Static).update(text)

    def _clear_display(self) -> None:
        self._current = None
        self._set_message("")
        self.query_one("#evaluated", Static).update("")
        self.query_one("#banner").display = False
        self.query_one("#verdict", Static).update("")
        self.query_one("#vote-status", Static).update("")
        for n in range(1, 6):
            row = self.query_one(f"#stage-{n}", Static)
            row.update("")
            row.remove_class("dim")
        self._set_vote_buttons(False)

    def _show(self, p: dict) -> None:
        self._clear_display()
        self._current = p
        d = decision_of(p)
        # what the server evaluated, not what the input holds now
        self.query_one("#evaluated", Static).update(evaluated_text(p))
        self.query_one("#banner").display = bool(p.get("silos_empty"))
        self.query_one("#verdict", Static).update(verdict_text(d))
        stages = {s.get("stage"): s for s in p.get("stages") or [] if isinstance(s, dict)}
        for n in range(1, 6):
            row = self.query_one(f"#stage-{n}", Static)
            stage = stages.get(n)
            if stage is None:
                continue
            row.update(stage_row(stage))
            row.set_class(stage.get("outcome") == "not_reached", "dim")
        pid = str(p.get("id"))
        self.query_one("#vote-status", Static).update(
            self._vote_closed.get(pid) or vote_status(p, self._accumulated.get(pid)))
        self._set_vote_buttons(self._votable(p))

    def _votable(self, p: dict) -> bool:
        token = p.get("token")
        return (str(p.get("id")) not in self._vote_closed and decision_of(p).get("kind") == "permitted_with_weight" and p.get("vote") is None
                and isinstance(token, dict) and token.get("spent") is False)

    def _set_vote_buttons(self, enabled: bool) -> None:
        for bid in ("#vote-yes", "#vote-no"):
            self.query_one(bid, Button).disabled = not enabled

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        event.stop()
        item = event.item
        if isinstance(item, HistoryItem) and not self._busy:
            p = self._session.get(item.proposal_id)
            if p is not None:
                self._show(p)

    # --- vote -------------------------------------------------------------
    def _start_vote(self, vote: str) -> None:
        p = self._current
        if p is None or self._voting or not self._votable(p):
            return
        self._voting = True
        self._set_vote_buttons(False)  # before the request: one vote per proposal
        self.query_one("#vote-status", Static).update("voting…")
        pid = str(p.get("id"))
        run_in_background(self, lambda: self._vote_worker(pid, vote), name="kudzu-vote")

    def _vote_worker(self, pid: str, vote: str) -> None:
        proposal = accumulated = error = None
        try:
            result = self.api.vote(pid, vote)
            proposal, accumulated = result["proposal"], result.get("accumulated_weight")
            if not isinstance(proposal, dict):
                raise TypeError("proposal is not an object")
        except KudzuAPIError as exc:
            error = exc
        except Exception:
            error = KudzuAPIError(None, "bad_response", {})
        self._post(VoteCast(pid, proposal, accumulated, error))

    def on_vote_cast(self, message: VoteCast) -> None:
        self._voting = False
        pid = message.proposal_id
        showing = self._current is not None and str(self._current.get("id")) == pid
        if message.error is None:
            self._session[pid] = message.proposal
            self._accumulated[pid] = message.accumulated
            from ..app import LedgerChanged  # late import: app imports this module
            self.app.post_message(LedgerChanged())
            if showing:
                self._show(message.proposal)
            return
        code = message.error.code
        if code in TERMINAL_VOTE_ERRORS:  # remembered so a history re-display stays closed
            self._vote_closed[pid] = "already voted" if code == "already_voted" else f"✗ {code}"
        if not showing:
            return
        status = self.query_one("#vote-status", Static)
        if code == "ledger_unavailable":
            status.update("ledger unavailable — try again")
            self._set_vote_buttons(True)  # still votable server-side
        elif code == "unreachable":
            status.update("✗ server unreachable — try again")
            # Connection failure or read timeout: the request may or may not have reached the
            # server. Retrying is safe: if the vote landed, the server answers 409 already_voted.
            self._set_vote_buttons(True)
        elif code == "already_voted":
            status.update("already voted")
        else:
            status.update(f"✗ {code}")
