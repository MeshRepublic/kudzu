import threading

from textual.widgets import Static

from kudzu_console.api import KudzuAPIError
from kudzu_console.app import KudzuConsole, LedgerChanged
from kudzu_console.views import ledger_format as fmt
from test_app import SETTINGS


def entry(pid, principle, weight, at, anchor="pending"):
    return {"proposal_id": pid, "principle": principle, "weight": weight,
            "vote_outcome": "yes_with_weight", "anchor_status": anchor, "recorded_at": at}


# newest first, as the server sends them
E1 = entry("p-3", "fairness", 0.4, "2026-11-20T10:00:00Z")
E2 = entry("p-2", "autonomy", 0.9, "2026-11-19T09:30:00+00:00", "anchored")
E3 = entry("p-1", "fairness", 0.7, "2026-11-18T08:15:30Z")
LEDGER = {"entries": [E1, E2, E3], "totals": {"fairness": 1.1, "autonomy": 0.9}, "tau_a": 1.0}


class LAPI:
    def __init__(self, ledger=LEDGER):
        self.ledger_data = ledger
        self.error = None
        self.calls = 0
        self.gate = None
        self.threads = []

    def health(self):
        return {"status": "ok", "holograms": 1}

    def governance_status(self):
        return {"silos": {"expertise": 1, "rejection": 1, "contested": 1}, "model": "m"}

    def ledger(self):
        self.calls += 1
        self.threads.append(threading.current_thread())
        if self.gate:
            self.gate.wait(5)
        if self.error:
            raise self.error
        return self.ledger_data


class LConsole(KudzuConsole):
    def __init__(self, api):
        super().__init__(api, SETTINGS, poll_interval=3600, copy_notice_seconds=30)
        self.clipboard_log = []

    def copy_to_clipboard(self, text):
        self.clipboard_log.append(text)


async def settle(app, pilot):
    await app.query_one("#view-ledger").workers.wait_for_complete()
    await pilot.pause()
    await pilot.pause()


async def open_view(app, pilot):
    await pilot.press("f4")
    await settle(app, pilot)


def rows(app):
    return [str(r.render()) for r in app.query("#view-ledger #entries .row").results(Static)]


def principles(app):
    return [r.split()[2] for r in rows(app)]


def totals(app):
    return list(app.query("#view-ledger #totals .total"))


# --- pure helpers -----------------------------------------------------------
def test_fmt_time_utc_and_fallback():
    assert fmt.fmt_time("2026-11-20T10:00:00Z") == "2026-11-20 10:00:00"
    assert fmt.fmt_time("2026-11-20T12:00:00+02:00") == "2026-11-20 10:00:00"
    assert fmt.fmt_time("2026-11-20T10:00:00.123456+00:00") == "2026-11-20 10:00:00"
    assert fmt.fmt_time("yesterday") == "yesterday"


def test_total_label_and_over():
    assert fmt.total_label("fairness", 1.1, 1.0) == "fairness  1.10 / 1.00"
    assert fmt.is_over(1.1, 1.0) and not fmt.is_over(1.0, 1.0)


def test_sort_weight_is_numeric_time_chronological():
    es = [entry("a", "x", 10.0, "2026-01-02T00:00:00Z"), entry("b", "x", 9.0, "2026-01-01T00:00:00Z")]
    assert [e["proposal_id"] for e in fmt.sort_entries(es, "weight")] == ["b", "a"]
    assert [e["proposal_id"] for e in fmt.sort_entries(es, "time")] == ["b", "a"]
    assert [e["proposal_id"] for e in fmt.sort_entries(es, "time", True)] == ["a", "b"]
    assert fmt.sort_entries(es, None) == es


def test_unparseable_time_sorts_last_and_filter():
    es = [entry("a", "x", 1.0, "junk"), entry("b", "y", 1.0, "2026-01-01T00:00:00Z")]
    assert [e["proposal_id"] for e in fmt.sort_entries(es, "time")] == ["b", "a"]
    assert fmt.filter_entries(es, "y") == [es[1]] and fmt.filter_entries(es, None) == es


def test_parse_ledger_rejects_malformed():
    assert fmt.parse_ledger({"entries": 3, "totals": {}, "tau_a": 1.0}) is None
    assert fmt.parse_ledger({"entries": [{"weight": 1}], "totals": {}, "tau_a": 1.0}) is None
    assert fmt.parse_ledger(None) is None
    assert fmt.parse_ledger(LEDGER) is not None


# --- pilot ------------------------------------------------------------------
async def test_renders_rows_and_totals_with_over_class():
    app = LConsole(LAPI())
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        assert len(rows(app)) == 3
        assert "2026-11-20 10:00:00" in rows(app)[0] and "0.40" in rows(app)[0] and "p-3" in rows(app)[0]
        ts = totals(app)
        assert [str(t.render()) for t in ts] == ["autonomy  0.90 / 1.00", "fairness  1.10 / 1.00"]
        assert [t.has_class("over") for t in ts] == [False, True]
        assert app.query_one("#ledger-message").render().plain == ""
        assert app.api.threads[0] is not threading.main_thread()


async def test_weight_header_sorts_ascending_then_descending_with_arrow():
    app = LConsole(LAPI())
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        head = app.query_one("#head-weight")
        await pilot.click("#head-weight")
        await pilot.pause()
        assert [r.split()[3] for r in rows(app)] == ["0.40", "0.70", "0.90"]
        assert "▲" in str(head.render())
        await pilot.click("#head-weight")
        await pilot.pause()
        assert [r.split()[3] for r in rows(app)] == ["0.90", "0.70", "0.40"]
        assert "▼" in str(head.render())
        await pilot.click("#head-principle")
        await pilot.pause()
        assert "▼" not in str(head.render()) and "▲" not in str(head.render())
        assert principles(app) == ["autonomy", "fairness", "fairness"]


async def test_keyboard_sort_and_filter():
    app = LConsole(LAPI())
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        app.query_one("#head-weight").focus()
        await pilot.press("enter")
        await pilot.pause()
        assert [r.split()[3] for r in rows(app)] == ["0.40", "0.70", "0.90"]
        await pilot.press("space")
        await pilot.pause()
        assert [r.split()[3] for r in rows(app)] == ["0.90", "0.70", "0.40"]
        totals(app)[1].focus()  # fairness
        await pilot.press("enter")
        await pilot.pause()
        assert principles(app) == ["fairness", "fairness"]
        assert totals(app)[1].has_class("active")


async def test_total_filters_composes_with_sort_and_toggles_off():
    app = LConsole(LAPI())
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await pilot.click("#head-weight")
        await pilot.click(totals(app)[1])
        await pilot.pause()
        assert [r.split()[3] for r in rows(app)] == ["0.40", "0.70"]
        assert totals(app)[1].has_class("active") and not totals(app)[0].has_class("active")
        await pilot.click(totals(app)[1])
        await pilot.pause()
        assert len(rows(app)) == 3 and not totals(app)[1].has_class("active")


async def test_empty_ledger_shows_empty_text():
    app = LConsole(LAPI({"entries": [], "totals": {}, "tau_a": 1.0}))
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        assert app.query_one("#ledger-message").render().plain == "No ratified weights yet."
        assert rows(app) == [] and totals(app) == []


async def test_error_shows_inline_error_clears_data_and_not_empty_text():
    api = LAPI()
    app = LConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        assert rows(app)
        api.error = KudzuAPIError(503, "unreachable", None)
        await pilot.press("f1")
        await pilot.press("f4")
        await settle(app, pilot)
        text = app.query_one("#ledger-message").render().plain
        assert "unreachable" in text and "No ratified weights yet." not in text
        assert rows(app) == [] and totals(app) == []


async def test_unexpected_error_and_bad_response_are_inline():
    for fail in (RuntimeError("boom"), "bad"):
        api = LAPI()
        if fail == "bad":
            api.ledger_data = {"entries": "x"}
        else:
            api.error = fail
        app = LConsole(api)
        async with app.run_test() as pilot:
            await open_view(app, pilot)
            assert "could not load" in app.query_one("#ledger-message").render().plain
            assert rows(app) == []


async def test_ledger_changed_triggers_one_call_when_shown():
    api = LAPI()
    app = LConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        assert api.calls == 1
        api.ledger_data = {"entries": [E1], "totals": {"fairness": 0.4}, "tau_a": 1.0}
        app.post_message(LedgerChanged())
        await settle(app, pilot)
        assert api.calls == 2
        assert len(rows(app)) == 1


async def test_ledger_changed_while_hidden_refreshes_once_on_show():
    api = LAPI()
    app = LConsole(api)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.post_message(LedgerChanged())
        await settle(app, pilot)
        assert api.calls == 0  # hidden: marked stale, loaded on show
        await open_view(app, pilot)
        assert api.calls == 1 and len(rows(app)) == 3


async def test_refresh_keeps_sort_and_filter_or_clears_missing_filter():
    api = LAPI()
    app = LConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        await pilot.click("#head-weight")
        await pilot.click(totals(app)[1])
        await pilot.pause()
        app.post_message(LedgerChanged())
        await settle(app, pilot)
        assert [r.split()[3] for r in rows(app)] == ["0.40", "0.70"]
        assert totals(app)[1].has_class("active")
        api.ledger_data = {"entries": [E2], "totals": {"autonomy": 0.9}, "tau_a": 1.0}
        app.post_message(LedgerChanged())
        await settle(app, pilot)
        assert principles(app) == ["autonomy"] and not totals(app)[0].has_class("active")
        assert "▲" in str(app.query_one("#head-weight").render())


async def test_stale_result_does_not_overwrite_newer():
    api = LAPI()
    app = LConsole(api)
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        view = app.query_one("#view-ledger")
        view._seq += 1  # a newer load is in flight
        from kudzu_console.views.ledger import LedgerLoaded
        view.post_message(LedgerLoaded(view._seq - 1, None, "error"))
        await pilot.pause()
        assert len(rows(app)) == 3


async def test_drag_across_row_copies_its_text():
    app = LConsole(LAPI())
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        row = app.query("#view-ledger #entries .row").first()
        await pilot.mouse_down(row, offset=(0, 0))
        await pilot.hover(row, offset=(9, 0))
        await pilot.mouse_up(row, offset=(9, 0))
        await pilot.pause()
        assert app.clipboard_log and app.clipboard_log[0].startswith("2026-11-20")


async def test_drag_across_total_copies_its_text():
    app = LConsole(LAPI())
    async with app.run_test() as pilot:
        await open_view(app, pilot)
        cell = totals(app)[0]
        await pilot.mouse_down(cell, offset=(1, 0))
        await pilot.hover(cell, offset=(8, 0))
        await pilot.mouse_up(cell, offset=(8, 0))
        await pilot.pause()
        assert app.clipboard_log and app.clipboard_log[0].startswith("autonomy")


async def test_narrow_wraps_totals_and_drops_proposal_id():
    app = LConsole(LAPI())
    async with app.run_test(size=(70, 24)) as pilot:
        await open_view(app, pilot)
        assert app.has_class("narrow")
        a, b = totals(app)
        assert a.region.y != b.region.y and a.region.height == 1
        assert not app.query_one("#head-proposal").display
        assert all("p-3" not in r for r in rows(app)) and len(rows(app)) == 3
        assert app.query_one("#head-weight").region.right <= 70
