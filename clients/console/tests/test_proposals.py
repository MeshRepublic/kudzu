import threading

import pytest
from textual.widgets import Button, Input, ListView, Select, Static

from kudzu_console.api import KudzuAPIError
from kudzu_console.app import KudzuConsole, LedgerChanged
from kudzu_console.views import proposals_format as fmt
from test_app import SETTINGS

PRINCIPLES = [f"Principle {i}" for i in range(1, 14)]


def stage(n, name, outcome, detail=None):
    return {"stage": n, "name": name, "outcome": outcome, "detail": detail or {}}


def make_proposal(kind="permitted", pid="p1", **over):
    nr = "not_reached"
    stages = {
        "permitted": [stage(1, "direct rejection match", "no_match", {"best_similarity": 0.31, "tau_r": 0.8}),
                      stage(2, "accumulated weight", "no_match", {"accumulated_weight": 0.0, "tau_a": 1.0, "best_similarity": None}),
                      stage(3, "expertise match", "permitted", {"best_similarity": 0.9, "threshold": 0.7}),
                      stage(4, "AI judge", nr), stage(5, "decision", "permitted", {"weight": None, "citation": "Art. I §8"})],
        "denied": [stage(1, "direct rejection match", "denied", {"best_similarity": 0.91, "tau_r": 0.8}),
                   stage(2, "accumulated weight", nr), stage(3, "expertise match", nr),
                   stage(4, "AI judge", nr), stage(5, "decision", "denied", {})],
        "denied_by_accumulation": [stage(1, "direct rejection match", "no_match", {"best_similarity": None, "tau_r": 0.8}),
                                   stage(2, "accumulated weight", "denied", {"accumulated_weight": 2.5, "tau_a": 2.0, "best_similarity": 0.8}),
                                   stage(3, "expertise match", nr), stage(4, "AI judge", nr),
                                   stage(5, "decision", "denied_by_accumulation", {})],
        "permitted_with_weight": [stage(1, "direct rejection match", "no_match", {"best_similarity": None, "tau_r": 0.8}),
                                  stage(2, "accumulated weight", "no_match", {"accumulated_weight": 0.5, "tau_a": 2.0, "best_similarity": 0.6}),
                                  stage(3, "expertise match", "insufficient", {"best_similarity": 0.4, "threshold": 0.7}),
                                  stage(4, "AI judge", "retards", {"confidence": 0.75, "tally": {"advances": 1, "retards": 2, "ambiguous": 0}, "reasoning": "r", "evidence": [], "error": None}),
                                  stage(5, "decision", "permitted_with_weight", {"weight": 0.65, "citation": None})],
        "cannot_evaluate": [stage(1, "direct rejection match", "no_match", {"best_similarity": None, "tau_r": 0.8}),
                            stage(2, "accumulated weight", "no_match", {"accumulated_weight": 0.0, "tau_a": 2.0, "best_similarity": None}),
                            stage(3, "expertise match", "insufficient", {"best_similarity": None, "threshold": 0.7}),
                            stage(4, "AI judge", "error", {"error": "judge timed out"}),
                            stage(5, "decision", "cannot_evaluate", {})],
    }[kind]
    decision = {"kind": kind, "weight": 0.65 if kind == "permitted_with_weight" else None,
                "citation": "Art. I §8" if kind == "permitted" else None, "principle": None,
                "reason": "judge unavailable: try later" if kind == "cannot_evaluate" else None,
                "reasoning": None, "evidence": None, "accumulated_ids": None}
    p = {"id": pid, "text": "Ban all widgets", "principle": PRINCIPLES[0], "silos_empty": False, "vote": None,
         "token": {"id": "t1", "spent": False}, "evaluated_at": "2026-11-20T00:00:00Z",
         "decision": decision, "stages": stages}
    p.update(over)
    return p


class PAPI:
    def __init__(self, kind="permitted_with_weight", **over):
        self.kind, self.over = kind, over
        self.principles = PRINCIPLES
        self.status_error = None
        self.eval_error = None
        self.vote_error = None
        self.gate = None
        self.evaluated, self.votes, self.threads = [], [], []
        self.n = 0

    def health(self):
        return {"status": "ok", "holograms": 1}

    def governance_status(self):
        if self.status_error:
            raise self.status_error
        return {"silos": {"expertise": 1, "rejection": 1, "contested": 1}, "model": "m", "principles": self.principles}

    def evaluate_proposal(self, text, principle):
        self.threads.append(threading.current_thread())
        self.evaluated.append((text, principle))
        if self.gate:
            self.gate.wait(5)
        if self.eval_error:
            raise self.eval_error
        self.n += 1
        return {"proposal": make_proposal(self.kind, pid=f"p{self.n}", text=text, principle=principle, **self.over)}

    def vote(self, pid, vote):
        self.votes.append((pid, vote))
        if self.vote_error:
            raise self.vote_error
        p = make_proposal(self.kind, pid=pid, vote=vote, token={"id": "t1", "spent": True})
        return {"proposal": p, "accumulated_weight": 1.25}


class PConsole(KudzuConsole):
    def __init__(self, api):
        super().__init__(api, SETTINGS, poll_interval=3600, copy_notice_seconds=30)
        self.clipboard_log = []
        self.ledger_changes = 0

    def copy_to_clipboard(self, text):
        self.clipboard_log.append(text)

    def on_ledger_changed(self, message):
        self.ledger_changes += 1


async def settle(app, pilot):
    await app.query_one("#view-proposals").workers.wait_for_complete()
    await pilot.pause()
    await pilot.pause()


async def open_view(app, pilot):
    await pilot.press("f2")
    await settle(app, pilot)


async def evaluate(app, pilot, text="Ban all widgets", principle=PRINCIPLES[0]):
    app.query_one("#proposal-input", Input).value = text
    app.query_one("#principle-select", Select).value = principle
    await pilot.pause()
    await pilot.click("#evaluate")
    await settle(app, pilot)


def text_of(app, sel):
    return str(app.query_one(sel, Static).render())


def disabled(app, sel):
    return app.query_one(sel, Button).disabled


# --- pure formatting --------------------------------------------------------
@pytest.mark.parametrize("kind,expected", [
    ("permitted", "✓ PERMITTED"), ("denied", "✗ DENIED"),
    ("denied_by_accumulation", "✗ DENIED — accumulated weight"),
    ("permitted_with_weight", "⚖ PERMITTED WITH WEIGHT 0.65 — needs a vote"),
    ("cannot_evaluate", "? CANNOT EVALUATE")])
def test_headlines(kind, expected):
    assert fmt.headline(make_proposal(kind)["decision"]) == expected


def test_stage_details():
    d = fmt.stage_detail
    assert d(stage(1, "x", "no_match", {"best_similarity": None, "tau_r": 0.8})) == "no match"
    assert d(stage(1, "x", "denied", {"best_similarity": 0.912, "tau_r": 0.8})) == "best 0.91 vs τ_R 0.80"
    assert d(stage(1, "x", "denied", {"best_similarity": 0.9, "tau_r": None})) == "best 0.90 vs τ_R —"
    assert d(stage(2, "x", "denied", {"accumulated_weight": 2.5, "tau_a": 2.0})) == "weight 2.50 vs τ_A 2.00"
    assert d(stage(2, "x", "no_match", {"accumulated_weight": None, "tau_a": None})) == "weight — vs τ_A —"
    assert d(stage(3, "x", "insufficient", {"best_similarity": None, "threshold": 0.7})) == "no match"
    assert d(stage(3, "x", "permitted", {"best_similarity": 0.9, "threshold": 0.7})) == "best 0.90 vs 0.70"
    tally = {"advances": 1, "retards": 2, "ambiguous": 0}
    assert d(stage(4, "x", "retards", {"confidence": 0.75, "tally": tally})) == "2/3 retards · confidence 0.75"
    assert d(stage(4, "x", "advances", {"confidence": 0.5, "tally": None})) == "confidence 0.50"
    assert d(stage(4, "x", "ambiguous", {"confidence": None, "tally": None})) == "confidence —"
    assert d(stage(4, "x", "error", {"error": "boom"})) == "boom"
    assert d(stage(4, "x", "not_reached")) == "—"
    assert d(stage(5, "x", "permitted_with_weight", {"weight": 0.65, "citation": None})) == "permitted_with_weight · weight 0.65"
    assert d(stage(5, "x", "permitted", {"weight": None, "citation": "Art. I"})) == "permitted · Art. I"
    assert d(stage(5, "x", "denied", {})) == "denied"
    assert d(stage(2, "x", "not_reached")) == "—"


def test_history_label_truncates_to_40():
    p = make_proposal("denied", text="x" * 60)
    assert fmt.history_label(p) == "✗ " + "x" * 40


# --- view -------------------------------------------------------------------
async def test_principle_select_holds_server_principles():
    app = PConsole(PAPI())
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        select = app.query_one("#principle-select", Select)
        assert [v for _, v in select._options if v is not Select.NULL] == PRINCIPLES
        assert select.is_blank()


async def test_evaluate_disabled_until_text_and_principle():
    app = PConsole(PAPI())
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        assert disabled(app, "#evaluate")
        app.query_one("#proposal-input", Input).value = "   "
        app.query_one("#principle-select", Select).value = PRINCIPLES[0]
        await pilot.pause()
        assert disabled(app, "#evaluate")
        app.query_one("#proposal-input", Input).value = "a law"
        await pilot.pause()
        assert not disabled(app, "#evaluate")
        app.query_one("#principle-select", Select).clear()
        await pilot.pause()
        assert disabled(app, "#evaluate")


@pytest.mark.parametrize("kind,headline", [
    ("permitted", "✓ PERMITTED"), ("denied", "✗ DENIED"),
    ("denied_by_accumulation", "✗ DENIED — accumulated weight"),
    ("permitted_with_weight", "⚖ PERMITTED WITH WEIGHT 0.65 — needs a vote"),
    ("cannot_evaluate", "? CANNOT EVALUATE")])
async def test_each_decision_kind_headline_and_stage_rows(kind, headline):
    api = PAPI(kind)
    app = PConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        assert text_of(app, "#verdict").splitlines()[0] == headline
        rows = [text_of(app, f"#stage-{n}") for n in range(1, 6)]
        assert [r.split()[0] for r in rows] == ["1", "2", "3", "4", "5"]
        assert "direct rejection match" in rows[0] and "decision" in rows[4] and kind in rows[4]
        for n, row in enumerate(rows, 1):
            dimmed = "not_reached" in row
            assert app.query_one(f"#stage-{n}").has_class("dim") == dimmed
            if dimmed:
                assert row.rstrip().endswith("—")
        assert api.evaluated == [("Ban all widgets", PRINCIPLES[0])]


async def test_weighted_stage_rows_show_tally():
    app = PConsole(PAPI("permitted_with_weight"))
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        assert "2/3 retards · confidence 0.75" in text_of(app, "#stage-4")
        assert "weight 0.50 vs τ_A 2.00" in text_of(app, "#stage-2")
        assert "no match" in text_of(app, "#stage-1")  # null similarity is never 0.00


async def test_banner_exact_when_silos_empty_hidden_otherwise():
    api = PAPI("permitted", silos_empty=True)
    app = PConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        assert not app.query_one("#banner").display
        await evaluate(app, pilot)
        assert app.query_one("#banner").display
        assert text_of(app, "#banner") == "Judge only — no distilled Constitution loaded"
        api.over = {"silos_empty": False}
        await evaluate(app, pilot, "another")
        assert not app.query_one("#banner").display


async def test_cannot_evaluate_shows_reason_and_disables_votes():
    app = PConsole(PAPI("cannot_evaluate"))
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        assert "judge unavailable: try later" in text_of(app, "#verdict")
        assert disabled(app, "#vote-yes") and disabled(app, "#vote-no")


async def test_votes_enabled_only_for_weighted_with_unspent_token():
    api = PAPI("permitted_with_weight")
    app = PConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        assert not disabled(app, "#vote-yes") and not disabled(app, "#vote-no")
        api.over = {"token": {"id": "t", "spent": True}}
        await evaluate(app, pilot, "spent one")
        assert disabled(app, "#vote-yes") and disabled(app, "#vote-no")
        api.kind = "permitted"
        api.over = {}
        await evaluate(app, pilot, "plain")
        assert disabled(app, "#vote-yes")


async def test_double_press_votes_once_and_shows_result():
    api = PAPI()
    app = PConsole(api)
    async with app.run_test(size=(100, 45)) as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        await pilot.click("#vote-yes")
        await pilot.click("#vote-yes")
        assert disabled(app, "#vote-yes") and disabled(app, "#vote-no")
        await settle(app, pilot)
        assert api.votes == [("p1", "yes")]
        assert text_of(app, "#vote-status") == f"voted yes · accumulated {PRINCIPLES[0]}: 1.25"
        assert disabled(app, "#vote-yes") and disabled(app, "#vote-no")
        assert app.ledger_changes == 1


async def test_vote_buttons_disable_before_request_is_sent():
    api = PAPI()
    app = PConsole(api)
    gate = threading.Event()
    orig = api.vote

    def slow_vote(pid, vote):
        gate.wait(5)
        return orig(pid, vote)
    api.vote = slow_vote
    async with app.run_test(size=(100, 45)) as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        await pilot.click("#vote-no")
        assert disabled(app, "#vote-yes") and disabled(app, "#vote-no")  # still in flight
        gate.set()
        await settle(app, pilot)
        assert app.ledger_changes == 1


@pytest.mark.parametrize("err,expected,reenabled", [
    (KudzuAPIError(409, "already_voted", {}), "already voted", False),
    (KudzuAPIError(404, "not_found", {}), "not_found", False),
    (KudzuAPIError(422, "not_votable", {}), "not_votable", False),
    (KudzuAPIError(422, "invalid_vote", {}), "invalid_vote", False),
    (KudzuAPIError(503, "ledger_unavailable", {}), "ledger unavailable — try again", True),
    (KudzuAPIError(None, "unreachable", {}), "unreachable", True),
])
async def test_vote_errors_inline_and_no_ledger_event(err, expected, reenabled):
    api = PAPI()
    api.vote_error = err
    app = PConsole(api)
    async with app.run_test(size=(100, 45)) as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        await pilot.click("#vote-yes")
        await settle(app, pilot)
        assert expected in text_of(app, "#vote-status")
        assert disabled(app, "#vote-yes") is not reenabled
        assert disabled(app, "#vote-no") is not reenabled
        assert app.ledger_changes == 0


async def test_unreachable_evaluate_shows_error_and_clears_previous_verdict():
    api = PAPI("denied")
    app = PConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        assert "DENIED" in text_of(app, "#verdict")
        api.eval_error = KudzuAPIError(None, "unreachable", {})
        await evaluate(app, pilot, "second")
        assert text_of(app, "#verdict") == ""
        assert all(text_of(app, f"#stage-{n}") == "" for n in range(1, 6))
        assert "evaluation failed" in text_of(app, "#message")
        assert "unreachable" in text_of(app, "#message")
        assert not disabled(app, "#evaluate")


async def test_evaluate_runs_in_worker_shows_evaluating_and_ignores_extra_presses():
    api = PAPI("denied")
    api.gate = threading.Event()
    app = PConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        app.query_one("#proposal-input", Input).value = "a law"
        app.query_one("#principle-select", Select).value = PRINCIPLES[0]
        await pilot.pause()
        await pilot.click("#evaluate")
        await pilot.pause()
        assert str(app.query_one("#evaluate", Button).label) == "evaluating…"
        app.query_one("#proposal-input", Input).focus()
        await pilot.press("enter")
        await pilot.pause()
        api.gate.set()
        await settle(app, pilot)
        assert len(api.evaluated) == 1
        assert api.threads[0] is not threading.main_thread()
        assert str(app.query_one("#evaluate", Button).label) == "Evaluate"
        assert "DENIED" in text_of(app, "#verdict")


async def test_enter_in_input_evaluates_when_valid_and_tab_order():
    api = PAPI("denied")
    app = PConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        inp = app.query_one("#proposal-input", Input)
        inp.focus()
        await pilot.press("enter")  # invalid: nothing happens
        await pilot.pause()
        assert api.evaluated == []
        await pilot.press(*"a law")
        app.query_one("#principle-select", Select).value = PRINCIPLES[0]
        await pilot.pause()
        await pilot.press("tab")
        assert app.focused.id == "principle-select"
        await pilot.press("tab")
        assert app.focused.id == "evaluate"
        inp.focus()
        await pilot.press("enter")
        await settle(app, pilot)
        assert len(api.evaluated) == 1


async def test_vote_buttons_follow_evaluate_in_tab_order_and_keyboard_vote():
    api = PAPI()
    app = PConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        app.query_one("#evaluate", Button).focus()
        await pilot.press("tab")
        assert app.focused.id == "vote-yes"
        await pilot.press("tab")
        assert app.focused.id == "vote-no"
        await pilot.press("shift+tab", "enter")
        await settle(app, pilot)
        assert api.votes == [("p1", "yes")]


async def test_principles_failure_disables_evaluate_and_retries_on_show():
    api = PAPI()
    api.status_error = KudzuAPIError(None, "unreachable", {})
    app = PConsole(api)
    async with app.run_test() as pilot:
        await pilot.press("f2")
        await settle(app, pilot)
        assert "principles could not be loaded" in text_of(app, "#message")
        app.query_one("#proposal-input", Input).value = "a law"
        await pilot.pause()
        assert disabled(app, "#evaluate")
        assert all(v is Select.NULL for _, v in app.query_one("#principle-select", Select)._options)
        api.status_error = None
        await pilot.press("f1")
        await pilot.pause()
        await pilot.press("f2")
        await settle(app, pilot)
        assert [v for _, v in app.query_one("#principle-select", Select)._options if v is not Select.NULL] == PRINCIPLES
        assert text_of(app, "#message") == ""


async def test_history_only_when_wide_and_click_redisplays_with_vote_state():
    api = PAPI()
    app = PConsole(api)
    async with app.run_test(size=(150, 40)) as pilot:
        await open_view(app, pilot)
        assert app.query_one("#history").display
        await evaluate(app, pilot, "first law " + "y" * 60)
        await pilot.click("#vote-yes")
        await settle(app, pilot)
        api.kind = "denied"
        await evaluate(app, pilot, "second law")
        assert "DENIED" in text_of(app, "#verdict")
        history = app.query_one("#history", ListView)
        assert len(history) == 2
        labels = [str(item.query_one("Label").render()) for item in history.children]
        assert labels == ["✗ second law", "⚖ first law " + "y" * 30]
        await pilot.click(history.children[1])
        await pilot.pause()
        assert "PERMITTED WITH WEIGHT" in text_of(app, "#verdict")
        assert text_of(app, "#vote-status").startswith("voted yes")
        assert disabled(app, "#vote-yes") and disabled(app, "#vote-no")
        history.focus()
        history.index = 0
        await pilot.press("enter")
        await pilot.pause()
        assert "DENIED" in text_of(app, "#verdict")


async def test_history_hidden_below_140_columns():
    app = PConsole(PAPI())
    async with app.run_test(size=(139, 40)) as pilot:
        await open_view(app, pilot)
        assert not app.query_one("#history").display
        await pilot.resize_terminal(140, 40)
        await pilot.pause()
        assert app.query_one("#history").display


async def test_narrow_view_stacks_verdict_below_input():
    app = PConsole(PAPI("denied"))
    async with app.run_test(size=(70, 24)) as pilot:
        await open_view(app, pilot)
        assert app.has_class("narrow")
        await evaluate(app, pilot)
        assert app.query_one("#verdict").region.y > app.query_one("#proposal-input").region.y


async def test_drag_across_verdict_copies_text():
    app = PConsole(PAPI("permitted"))
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot)
        verdict = app.query_one("#verdict")
        await pilot.mouse_down(verdict, offset=(0, 0))
        await pilot.hover(verdict, offset=(11, 0))
        await pilot.mouse_up(verdict, offset=(11, 0))
        await pilot.pause()
        assert app.clipboard_log == ["✓ PERMITTED"]


async def _vote_fail_then_redisplay(err):
    api = PAPI()
    api.vote_error = err
    app = PConsole(api)
    return api, app


@pytest.mark.parametrize("err,expected", [
    (KudzuAPIError(409, "already_voted", {}), "already voted"),
    (KudzuAPIError(404, "not_found", {}), "not_found"),
    (KudzuAPIError(422, "not_votable", {}), "not_votable"),
    (KudzuAPIError(422, "invalid_vote", {}), "invalid_vote"),
])
async def test_terminal_vote_failure_stays_closed_after_history_redisplay(err, expected):
    api, app = await _vote_fail_then_redisplay(err)
    async with app.run_test(size=(150, 45)) as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot, "first law")
        await pilot.click("#vote-yes")
        await settle(app, pilot)
        await evaluate(app, pilot, "second law")
        history = app.query_one("#history", ListView)
        await pilot.click(history.children[1])  # first proposal
        await pilot.pause()
        assert disabled(app, "#vote-yes") and disabled(app, "#vote-no")
        assert expected in text_of(app, "#vote-status")
        await pilot.click(history.children[0])
        await pilot.pause()
        assert not disabled(app, "#vote-yes")  # the other proposal is unaffected
        assert text_of(app, "#vote-status") == ""


@pytest.mark.parametrize("err", [KudzuAPIError(503, "ledger_unavailable", {}),
                                 KudzuAPIError(None, "unreachable", {})])
async def test_retryable_vote_failure_reenabled_after_history_redisplay(err):
    api, app = await _vote_fail_then_redisplay(err)
    async with app.run_test(size=(150, 45)) as pilot:
        await open_view(app, pilot)
        await evaluate(app, pilot, "first law")
        await pilot.click("#vote-yes")
        await settle(app, pilot)
        await evaluate(app, pilot, "second law")
        history = app.query_one("#history", ListView)
        await pilot.click(history.children[1])
        await pilot.pause()
        assert not disabled(app, "#vote-yes") and not disabled(app, "#vote-no")
