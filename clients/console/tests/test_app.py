import asyncio
import threading
import time

import pytest
from textual.widgets import Tabs

from kudzu_console.api import KudzuAPIError
from kudzu_console.app import KudzuConsole, PaletteCommand
from kudzu_console.config import Settings

SETTINGS = Settings(kudzu_host="http://100.70.67.110:4001")


class FakeAPI:
    def __init__(self, expertise=12, rejection=30, contested=7):
        self.silos = {"expertise": expertise, "rejection": rejection, "contested": contested}
        self.fail = None

    def health(self, timeout=None):
        if self.fail:
            raise self.fail
        return {"status": "ok", "holograms": 9}

    def governance_status(self, timeout=None):
        if self.fail:
            raise self.fail
        return {"silos": self.silos, "model": "claude-opus-5-5"}


class RecordingConsole(KudzuConsole):
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.commands = []

    def on_palette_command(self, message: PaletteCommand) -> None:
        self.commands.append(message.name)
        message.prevent_default()  # record only: don't forward to the chat view (it would hit the network)


def make(api=None, **kw):
    return RecordingConsole(api or FakeAPI(), SETTINGS, poll_interval=3600, **kw)


def header(app):
    return str(app.query_one("#status-header").render())


async def test_starts_on_chat_and_f2_switches():
    app = make()
    async with app.run_test() as pilot:
        assert app.query_one("#view-chat").display
        await pilot.press("f2")
        await pilot.pause()
        assert app.query_one("#view-proposals").display
        assert not app.query_one("#view-chat").display
        await pilot.press("f3")
        await pilot.pause()
        assert app.query_one("#view-antitrust").display
        await pilot.press("f4")
        await pilot.pause()
        assert app.query_one("#view-ledger").display


async def test_clicking_tab_switches_view():
    app = make()
    async with app.run_test() as pilot:
        await pilot.click("#tab-ledger")
        await pilot.pause()
        assert app.query_one("#view-ledger").display
        assert app.query_one(Tabs).active == "tab-ledger"


async def test_header_counts_and_empty_silos():
    app = make(FakeAPI())
    async with app.run_test() as pilot:
        await app.poll().wait()
        await pilot.pause()
        text = header(app)
        assert text == "Kudzu ── 100.70.67.110 ● 9 holograms ── claude-opus-5-5 ── silos: 12/30/7"
    app = make(FakeAPI(expertise=0))
    async with app.run_test() as pilot:
        await app.poll().wait()
        await pilot.pause()
        assert "silos: empty ⚠" in header(app)


async def test_disconnect_and_recovery():
    api = FakeAPI()
    app = make(api)
    async with app.run_test() as pilot:
        await app.poll().wait()
        api.fail = KudzuAPIError(None, "unreachable", {})
        await app.poll().wait()
        await pilot.pause()
        assert header(app) == "Kudzu ── disconnected ✗ (unreachable)"
        assert app.is_running
        api.fail = None
        await app.poll().wait()
        await pilot.pause()
        assert "9 holograms" in header(app)


async def test_interval_polls_automatically():
    api = FakeAPI()
    app = KudzuConsole(api, SETTINGS, poll_interval=0.05)
    async with app.run_test() as pilot:
        await pilot.pause(0.5)
        assert "9 holograms" in header(app)


async def test_narrow_class_toggles():
    app = make()
    async with app.run_test(size=(70, 24)) as pilot:
        await pilot.pause()
        assert app.has_class("narrow")
    app = make()
    async with app.run_test(size=(100, 24)) as pilot:
        await pilot.pause()
        assert not app.has_class("narrow")
        await pilot.resize_terminal(60, 24)
        await pilot.pause()
        assert app.has_class("narrow")


async def test_footer_hints_and_copy_notice():
    app = make(copy_notice_seconds=0.2)
    async with app.run_test() as pilot:
        hints = "F1 Chat  F2 Proposals  F3 Antitrust  F4 Ledger   ^K commands   ^Q quit"
        footer = lambda: str(app.query_one("#footer-hints").render())
        assert footer() == hints
        app.notify_copy("/tmp/x.md")
        await pilot.pause()
        assert footer() == "copied (/tmp/x.md)"
        await pilot.pause(0.5)
        assert footer() == hints


async def test_palette_lists_exactly_five_and_posts_command():
    app = make()
    async with app.run_test() as pilot:
        await pilot.press("ctrl+k")
        await pilot.pause()
        from textual.command import CommandPalette
        from textual.widgets import OptionList
        palette = app.screen
        assert isinstance(palette, CommandPalette)
        await pilot.pause(0.3)
        opts = palette.query_one(OptionList)
        assert opts.option_count == 5
        await pilot.press(*"traces", "enter")
        await pilot.pause(0.3)
        assert app.commands == ["traces"]


async def test_palette_quit_exits():
    app = make()
    async with app.run_test() as pilot:
        await pilot.press("ctrl+k")
        await pilot.pause(0.3)
        await pilot.press(*"quit", "enter")
        await pilot.pause(0.3)
    assert app._exit


async def test_ctrl_q_quits():
    app = make()
    async with app.run_test() as pilot:
        await pilot.press("ctrl+q")
        await pilot.pause()
    assert app._exit


class GatedAPI(FakeAPI):
    """Each governance_status call blocks until its gate is set; calls are numbered."""

    def __init__(self):
        super().__init__()
        self.gates = []
        self.entered = []
        self.results = []

    def governance_status(self, timeout=None):
        n = len(self.gates)
        gate, entered = threading.Event(), threading.Event()
        self.gates.append(gate)
        self.entered.append(entered)
        entered.set()
        gate.wait(5)
        r = self.results[n] if n < len(self.results) else None
        if isinstance(r, Exception):
            raise r
        return {"silos": self.silos, "model": r or "m"}


async def test_quit_while_poll_in_flight():
    api = GatedAPI()
    app = make(api)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert api.entered[0].wait(5)
        await pilot.press("ctrl+q")
        await pilot.pause()
    api.gates[0].set()
    await asyncio.sleep(0.3)  # let the released worker thread finish and try to hand off
    assert app._exit


async def test_stale_poll_does_not_overwrite_newer():
    api = GatedAPI()
    api.results = ["model-A", "model-B"]
    app = make(api)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert api.entered[0].wait(5)  # poll A (from mount) blocked
        # poll B starts while A's thread is still blocked; A's result is now stale
        wb = app.poll()
        for _ in range(100):
            if len(api.entered) > 1:
                break
            await pilot.pause(0.02)
        assert api.entered[1].wait(5)
        api.gates[1].set()
        await wb.wait()
        await pilot.pause()
        assert "model-B" in header(app)
        api.gates[0].set()
        await pilot.pause(0.3)
        assert "model-B" in header(app)
        assert "model-A" not in header(app)


async def test_unexpected_exception_shows_error_and_app_survives():
    api = FakeAPI()
    app = make(api)
    async with app.run_test() as pilot:
        api.fail = RuntimeError("boom")
        await app.poll().wait()
        await pilot.pause()
        assert "disconnected ✗ (error)" in header(app)
        assert app.is_running


def wait_until(predicate, timeout=5.0):
    """Block the calling (helper) thread until `predicate()` is true."""
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, "condition never became true"
        time.sleep(0.01)


def run_and_quit(app, drive, timeout=10.0):
    """Run `app` for real, as `main()` does (`App.run`), headless.

    `drive(app)` runs in a helper thread once the app is running; it starts a blocking fake-api
    call (using `app.call_from_thread`) and returns once that call is blocked. The helper then
    requests quit. Returns the seconds from the quit request until `App.run()` returned.
    """
    marks = {}

    def driver():
        deadline = time.monotonic() + timeout
        while not app.is_running and time.monotonic() < deadline:
            time.sleep(0.01)
        time.sleep(0.2)  # let mount finish
        drive(app)
        marks["quit"] = time.monotonic()
        app.call_from_thread(app.exit)

    helper = threading.Thread(target=driver, daemon=True)
    helper.start()
    app.run(headless=True, size=(100, 30))
    returned = time.monotonic()
    helper.join(2)
    assert "quit" in marks, "the drive step never finished"
    return returned - marks["quit"]


def test_quit_returns_promptly_while_poll_blocked():
    """Quitting never waits for a blocked network call (daemon threads, not executor workers)."""
    api = GatedAPI()
    app = make(api)
    try:
        elapsed = run_and_quit(app, lambda app: wait_until(lambda: api.entered and api.entered[0].is_set()))
        assert api.entered and not api.gates[0].is_set()  # the call is still blocked
        assert elapsed < 2
    finally:
        for gate in api.gates:
            gate.set()
    time.sleep(0.2)  # the released thread hands off to the finished app; must not raise


async def test_poll_passes_short_timeout():
    seen = []

    class TimeoutAPI(FakeAPI):
        def health(self, timeout=None):
            seen.append(("health", timeout))
            return super().health()

        def governance_status(self, timeout=None):
            seen.append(("status", timeout))
            return super().governance_status()

    app = make(TimeoutAPI())
    async with app.run_test() as pilot:
        await app.poll().wait()
        await pilot.pause()
    assert ("health", (3, 5)) in seen and ("status", (3, 5)) in seen
