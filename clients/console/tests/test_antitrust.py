import threading

import pytest
from textual.widgets import Button, Input, Static

from kudzu_console.api import KudzuAPIError
from kudzu_console.app import KudzuConsole
from kudzu_console.presets import PRESETS
from kudzu_console.views import antitrust_format as fmt
from kudzu_console.views.antitrust import FIELDS
from test_app import SETTINGS

TRIGGERED = {"result": "triggered",
             "concentration": {"share": 62.0, "threshold": 40.0, "met": True},
             "satisfaction": {"baseline": 81.0, "current": 68.0, "drop_pct": 16.05, "threshold": 10.0, "met": True}}
WATCH = {"result": "watch",
         "concentration": {"share": 55.0, "threshold": 40.0, "met": True},
         "satisfaction": {"baseline": 80.0, "current": 78.0, "drop_pct": 2.5, "threshold": 10.0, "met": False}}
NOT = {"result": "not_triggered",
       "concentration": {"share": 22.0, "threshold": 40.0, "met": False},
       "satisfaction": {"baseline": 75.0, "current": 60.0, "drop_pct": 20.0, "threshold": 10.0, "met": True}}
RISE = {"result": "not_triggered",
        "concentration": {"share": 22.5, "threshold": 40.0, "met": False},
        "satisfaction": {"baseline": 80.0, "current": 90.0, "drop_pct": -12.5, "threshold": 10.0, "met": False}}


class AAPI:
    def __init__(self, response=TRIGGERED):
        self.response = response
        self.defaults = {"share": 40.0, "satisfaction_drop": 10.0}
        self.status_error = None
        self.eval_error = None
        self.gate = None
        self.sent, self.threads, self.status_calls = [], [], 0

    def health(self):
        return {"status": "ok", "holograms": 1}

    def governance_status(self):
        self.status_calls += 1
        if self.status_error:
            raise self.status_error
        return {"silos": {"expertise": 1, "rejection": 1, "contested": 1}, "model": "m",
                "principles": [], "antitrust_defaults": self.defaults}

    def evaluate_antitrust(self, scenario):
        self.threads.append(threading.current_thread())
        self.sent.append(scenario)
        if self.gate:
            self.gate.wait(5)
        if self.eval_error:
            raise self.eval_error
        return self.response


class AConsole(KudzuConsole):
    def __init__(self, api):
        super().__init__(api, SETTINGS, poll_interval=3600, copy_notice_seconds=30)
        self.clipboard_log = []

    def copy_to_clipboard(self, text):
        self.clipboard_log.append(text)


async def settle(app, pilot):
    await app.query_one("#view-antitrust").workers.wait_for_complete()
    await pilot.pause()
    await pilot.pause()


async def open_view(app, pilot):
    await pilot.press("f3")
    await settle(app, pilot)


def val(app, sel):
    return app.query_one(sel, Input).value


def fill(app, share="62", base="81", cur="68"):
    app.query_one("#share", Input).value = share
    app.query_one("#baseline", Input).value = base
    app.query_one("#current", Input).value = cur


def result(app):
    return str(app.query_one("#result", Static).render())


def err(app, fid):
    return str(app.query_one(f"#err-{fid}", Static).render())


def invalid(app, fid):
    return app.query_one(f"#{fid}", Input).has_class("invalid")


async def run_eval(app, pilot):
    await pilot.click("#view-antitrust #evaluate")
    await settle(app, pilot)


# --- pure helpers -------------------------------------------------------------
def test_presets_are_four_fictional_triples():
    assert [(p["market_share"], p["baseline_satisfaction"], p["current_satisfaction"]) for p in PRESETS] == [
        (62, 81, 68), (55, 80, 78), (22, 75, 60), (40, 80, 72)]
    for p in PRESETS:
        assert set(p) == {"label", "company", "vertical", "market_share", "baseline_satisfaction", "current_satisfaction"}


def test_result_text_triggered():
    assert fmt.result_text(TRIGGERED) == "\n".join([
        "⚠ TRIGGERED — open-source methods",
        "Concentration  62% ≥ 40%  ✓",
        "Satisfaction   81 → 68  −16.05%  ✓",
        "               (limit −10%)",
        "Both metrics met (white paper §6.2). Company keeps its brand."])


def test_result_text_watch_and_not_triggered_and_rise():
    w = fmt.result_text(WATCH).splitlines()
    assert w[0] == "◐ WATCH — one metric met" and w[2] == "Satisfaction   80 → 78  −2.50%  ✗" and len(w) == 4
    n = fmt.result_text(NOT).splitlines()
    assert n[0] == "✓ NOT TRIGGERED" and n[1] == "Concentration  22% < 40%  ✗"
    r = fmt.result_text(RISE).splitlines()
    assert r[1] == "Concentration  22.5% < 40%  ✗" and r[2] == "Satisfaction   80 → 90  +12.50%  ✗"


@pytest.mark.parametrize("bad", [None, {}, {"result": "weird", "concentration": {}, "satisfaction": {}},
                                 {"result": "watch", "concentration": {}, "satisfaction": {}}])
def test_result_text_rejects_unusable(bad):
    assert fmt.result_text(bad) is None


BASE = {"company": "", "vertical": "", "share": "50", "baseline": "80", "current": "70", "th-share": "40", "th-drop": "10"}


@pytest.mark.parametrize("field,text,bad", [
    ("share", "abc", True), ("share", "", True), ("share", "-1", True), ("share", "100.5", True), ("share", "100", False),
    ("share", "0", False), ("baseline", "0", True), ("baseline", "-5", True), ("baseline", "nan", True),
    ("current", "x", True), ("current", "-1", True), ("current", "0", False), ("current", "inf", True),
    ("th-share", "abc", True), ("th-share", "-1", True), ("th-share", "0", False),
    ("th-drop", "", True), ("th-drop", "-0.5", True), ("th-drop", "5.5", False)])
def test_validate(field, text, bad):
    body, errors = fmt.validate({**BASE, field: text})
    assert (field in errors) is bad
    assert (body is None) is bad


def test_validate_body_shape():
    body, _ = fmt.validate({**BASE, "company": " Acme ", "th-drop": "12.5"})
    assert body == {"market_share": 50.0, "baseline_satisfaction": 80.0, "current_satisfaction": 70.0,
                    "company": "Acme", "thresholds": {"share": 40.0, "satisfaction_drop": 12.5}}


# --- view ---------------------------------------------------------------------
async def test_thresholds_prefill_from_server_defaults():
    api = AAPI()
    api.defaults = {"share": 33.0, "satisfaction_drop": 7.5}
    app = AConsole(api)
    async with app.run_test() as pilot:
        assert val(app, "#th-share") == "40" and val(app, "#th-drop") == "10"
        await open_view(app, pilot)
        assert (val(app, "#th-share"), val(app, "#th-drop")) == ("33", "7.5")
        assert str(app.query_one("#defaults-note", Static).render()) == ""


async def test_defaults_load_failure_prefills_and_notes_then_retries():
    api = AAPI()
    api.status_error = KudzuAPIError(None, "unreachable", {})
    app = AConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        assert (val(app, "#th-share"), val(app, "#th-drop")) == ("40", "10")
        assert "could not be confirmed" in str(app.query_one("#defaults-note", Static).render())
        api.status_error = None
        api.defaults = {"share": 45.0, "satisfaction_drop": 12.0}
        await pilot.press("f1")
        await pilot.press("f3")
        await settle(app, pilot)
        assert val(app, "#th-share") == "45"
        assert str(app.query_one("#defaults-note", Static).render()) == ""
        calls = api.status_calls
        await pilot.press("f1")
        await pilot.press("f3")
        await settle(app, pilot)
        assert api.status_calls == calls  # loaded: not asked again


@pytest.mark.parametrize("i", range(4))
async def test_preset_fills_fields_clears_result_sends_nothing(i):
    api = AAPI()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        assert result(app) and len(api.sent) == 1
        app.query_one("#th-share", Input).value = "41"
        await pilot.pause()
        await pilot.click(f"#preset-{i}")
        await pilot.pause()
        p = PRESETS[i]
        assert (val(app, "#company"), val(app, "#vertical")) == (p["company"], p["vertical"])
        assert (val(app, "#share"), val(app, "#baseline"), val(app, "#current")) == (
            str(p["market_share"]), str(p["baseline_satisfaction"]), str(p["current_satisfaction"]))
        assert val(app, "#th-share") == "41"  # thresholds untouched
        assert result(app) == "" and len(api.sent) == 1


async def test_preset_reachable_and_activatable_by_keyboard():
    api = AAPI()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        app.query_one("#preset-1", Button).focus()
        await pilot.press("enter")
        await pilot.pause()
        assert val(app, "#share") == "55"
        # Tab from the last preset reaches the first field
        app.query_one("#preset-3", Button).focus()
        await pilot.press("tab")
        assert app.focused.id == "company"


@pytest.mark.parametrize("resp,headline", [
    (TRIGGERED, "⚠ TRIGGERED — open-source methods"), (WATCH, "◐ WATCH — one metric met"), (NOT, "✓ NOT TRIGGERED")])
async def test_result_headlines_via_worker_thread(resp, headline):
    api = AAPI(resp)
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        assert result(app).splitlines()[0] == headline
        assert api.threads and api.threads[0] is not threading.main_thread()
        assert result(app) == fmt.result_text(resp)


async def test_edited_thresholds_and_optional_fields_are_sent():
    api = AAPI()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        app.query_one("#th-share", Input).value = "35"
        app.query_one("#th-drop", Input).value = "7.5"
        app.query_one("#company", Input).value = "Acme"
        await pilot.pause()
        await run_eval(app, pilot)
        assert api.sent == [{"market_share": 62.0, "baseline_satisfaction": 81.0, "current_satisfaction": 68.0,
                             "company": "Acme", "thresholds": {"share": 35.0, "satisfaction_drop": 7.5}}]


@pytest.mark.parametrize("share,base,cur,field", [
    ("abc", "81", "68", "share"), ("-3", "81", "68", "share"), ("101", "81", "68", "share"),
    ("62", "0", "68", "baseline"), ("62", "x", "68", "baseline"), ("62", "81", "-1", "current")])
async def test_invalid_input_sends_nothing_and_marks_field(share, base, cur, field):
    api = AAPI()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app, share, base, cur)
        await run_eval(app, pilot)
        assert api.sent == []
        assert invalid(app, field) and err(app, field)
        assert result(app) == ""
        # editing the field clears its mark
        app.query_one(f"#{field}", Input).value = "5"
        await pilot.pause()
        assert not invalid(app, field) and err(app, field) == ""


@pytest.mark.parametrize("fid,text", [("th-share", "abc"), ("th-drop", "-1")])
async def test_invalid_threshold_sends_nothing(fid, text):
    api = AAPI()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        app.query_one(f"#{fid}", Input).value = text
        await run_eval(app, pilot)
        assert api.sent == [] and invalid(app, fid)


async def test_validation_failure_clears_shown_result():
    app = AConsole(AAPI())
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        assert result(app)
        app.query_one("#share", Input).value = "abc"
        await pilot.pause()
        assert result(app) == ""  # editing cleared it already
        await run_eval(app, pilot)
        assert result(app) == ""


@pytest.mark.parametrize("field,fid", [
    ("market_share", "share"), ("baseline_satisfaction", "baseline"), ("current_satisfaction", "current"),
    ("share", "th-share"), ("satisfaction_drop", "th-drop")])
async def test_server_422_marks_named_field(field, fid):
    api = AAPI()
    api.eval_error = KudzuAPIError(422, "invalid", {"error": "invalid", "field": field})
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        assert invalid(app, fid) and err(app, fid)
        assert [f for f, _ in FIELDS if invalid(app, f)] == [fid]
        assert result(app) == ""


@pytest.mark.parametrize("field", ["thresholds", "scenario", "mystery"])
async def test_server_422_general_errors_mark_no_field(field):
    api = AAPI()
    api.eval_error = KudzuAPIError(422, "invalid", {"error": "invalid", "field": field})
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        assert str(app.query_one("#view-antitrust #message", Static).render()).startswith("✗")
        assert not any(app.query_one(f"#{f}").has_class("invalid") for f in ("share", "baseline", "current", "th-share", "th-drop"))


@pytest.mark.parametrize("exc,expected", [
    (KudzuAPIError(None, "unreachable", {}), "server unreachable"),
    (KudzuAPIError(500, "server_error", {}), "server_error"),
    (RuntimeError("boom"), "bad_response")])
async def test_request_failure_clears_result_and_shows_error(exc, expected):
    api = AAPI()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        assert result(app)
        api.eval_error = exc
        await run_eval(app, pilot)
        assert result(app) == ""
        assert expected in str(app.query_one("#view-antitrust #message", Static).render())
        assert not app.query_one("#view-antitrust #evaluate", Button).disabled


async def test_malformed_response_is_not_shown():
    app = AConsole(AAPI({"result": "triggered"}))
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        assert result(app) == "" and "bad_response" in str(app.query_one("#view-antitrust #message", Static).render())


async def test_editing_after_result_clears_it():
    app = AConsole(AAPI())
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        assert result(app)
        app.query_one("#company", Input).value = "Other"
        await pilot.pause()
        assert result(app) == ""


async def test_enter_in_any_field_evaluates_via_keyboard():
    api = AAPI()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        app.query_one("#th-drop", Input).focus()
        await pilot.press("enter")
        await settle(app, pilot)
        assert len(api.sent) == 1 and result(app)


async def test_single_flight_and_label_while_busy():
    api = AAPI()
    api.gate = threading.Event()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        app.query_one("#share", Input).focus()
        await pilot.press("enter")
        await pilot.pause()
        button = app.query_one("#view-antitrust #evaluate", Button)
        assert str(button.label) == "evaluating…"
        await pilot.press("enter")
        await pilot.press("enter")
        await pilot.pause()
        api.gate.set()
        await settle(app, pilot)
        assert len(api.sent) == 1
        assert str(button.label) == "Evaluate" and result(app)


async def test_result_arriving_after_edit_is_discarded():
    api = AAPI()
    api.gate = threading.Event()
    app = AConsole(api)
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        app.query_one("#share", Input).focus()
        await pilot.press("enter")
        await pilot.pause()
        app.query_one("#current", Input).value = "10"
        await pilot.pause()
        api.gate.set()
        await settle(app, pilot)
        assert result(app) == ""
        assert not app.query_one("#view-antitrust #evaluate", Button).disabled


async def test_narrow_stacks_scenario_above_result():
    app = AConsole(AAPI())
    async with app.run_test(size=(70, 24)) as pilot:
        await open_view(app, pilot)
        assert app.has_class("narrow")
        assert app.query_one("#result-panel").region.y > app.query_one("#scenario").region.y
        assert app.query_one("#result-panel").region.y >= app.query_one("#scenario").region.bottom
        assert app.query_one("#result-panel").region.width > 60


async def test_wide_puts_result_beside_scenario():
    app = AConsole(AAPI())
    async with app.run_test(size=(120, 40)) as pilot:
        await open_view(app, pilot)
        assert app.query_one("#result-panel").region.x >= app.query_one("#scenario").region.right


async def test_drag_across_result_headline_copies_text():
    app = AConsole(AAPI(NOT))
    async with app.run_test(size=(100, 40)) as pilot:
        await open_view(app, pilot)
        fill(app)
        await run_eval(app, pilot)
        widget = app.query_one("#result")
        await pilot.mouse_down(widget, offset=(0, 0))
        await pilot.hover(widget, offset=(15, 0))
        await pilot.mouse_up(widget, offset=(15, 0))
        await pilot.pause()
        assert app.clipboard_log == ["✓ NOT TRIGGERED"]
