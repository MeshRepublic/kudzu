"""Kudzu Console application shell: header, tabs, views, footer, polling."""
from __future__ import annotations

from pathlib import Path
from urllib.parse import urlparse

from textual import events
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.command import DiscoveryHit, Hit, Hits, Provider
from textual.message import Message
from textual.timer import Timer
from textual.widgets import ContentSwitcher, Static, Tab, Tabs
from textual.worker import Worker, get_current_worker

from .api import KudzuAPI, KudzuAPIError
from .clipboard import copy_text
from .config import Settings
from .views.antitrust import AntitrustView
from .views.chat import ChatView
from .views.ledger import LedgerView
from .views.proposals import ProposalsView

NARROW_WIDTH = 80
FOOTER_HINTS = "F1 Chat  F2 Proposals  F3 Antitrust  F4 Ledger   ^K commands   ^Q quit"
# (tab key, label, view id)
TABS = [
    ("chat", "Chat", "view-chat"),
    ("proposals", "Proposals", "view-proposals"),
    ("antitrust", "Antitrust", "view-antitrust"),
    ("ledger", "Ledger", "view-ledger"),
]
PALETTE_COMMANDS = ("status", "progress", "traces", "clear", "quit")


class PaletteCommand(Message):
    """Posted to the app when a palette command other than `quit` is chosen."""

    def __init__(self, name: str) -> None:
        super().__init__()
        self.name = name


class LedgerChanged(Message):
    """Posted to the app after every successful vote; the Ledger view listens for it."""


class StatusResult(Message):
    """Header text produced by a poll, tagged with the sequence number of that poll."""

    def __init__(self, seq: int, text: str) -> None:
        super().__init__()
        self.seq = seq
        self.text = text


class ConsoleCommands(Provider):
    """Command palette provider offering exactly the console commands."""

    async def discover(self) -> Hits:
        for name in PALETTE_COMMANDS:
            yield DiscoveryHit(name, self._runner(name), text=name)

    async def search(self, query: str) -> Hits:
        matcher = self.matcher(query)
        for name in PALETTE_COMMANDS:
            score = matcher.match(name)
            if score > 0:
                yield Hit(score, matcher.highlight(name), self._runner(name), text=name)

    def _runner(self, name: str):
        def run() -> None:
            self.app.run_palette_command(name)
        return run


class KudzuConsole(App):
    CSS_PATH = str(Path(__file__).with_name("app.tcss"))  # absolute: subclasses elsewhere still resolve it
    TITLE = "Kudzu"
    COMMANDS = {ConsoleCommands}
    COMMAND_PALETTE_BINDING = "ctrl+k"
    BINDINGS = [
        Binding("f1", "show_tab('chat')", "Chat"),
        Binding("f2", "show_tab('proposals')", "Proposals"),
        Binding("f3", "show_tab('antitrust')", "Antitrust"),
        Binding("f4", "show_tab('ledger')", "Ledger"),
        Binding("ctrl+q", "quit", "Quit", priority=True),
    ]

    def __init__(self, api: KudzuAPI, settings: Settings, *, poll_interval: float = 15.0,
                 copy_notice_seconds: float = 2.0) -> None:
        super().__init__()
        self.api = api
        self.settings = settings
        self.poll_interval = poll_interval
        self.copy_notice_seconds = copy_notice_seconds
        self._copy_timer: Timer | None = None
        self._poll_seq = 0  # sequence of the latest poll started
        self._applied_seq = 0  # sequence of the latest result shown

    def compose(self) -> ComposeResult:
        yield Static("Kudzu ── connecting…", id="status-header", markup=False)
        yield Tabs(*(Tab(label, id=f"tab-{key}") for key, label, _ in TABS), id="tabs")
        with ContentSwitcher(initial="view-chat", id="views"):
            yield ChatView(self.api, self.settings)
            yield ProposalsView(self.api, self.settings)
            yield AntitrustView(self.api, self.settings)
            yield LedgerView(self.api, self.settings)
        yield Static(FOOTER_HINTS, id="footer-hints", markup=False)

    def on_mount(self) -> None:
        self._update_narrow(self.size.width)
        self.set_interval(self.poll_interval, self.poll)
        self.poll()

    # --- layout -----------------------------------------------------------
    def on_resize(self, event: events.Resize) -> None:
        self._update_narrow(event.size.width)

    def _update_narrow(self, width: int) -> None:
        self.set_class(width < NARROW_WIDTH, "narrow")

    # --- tabs -------------------------------------------------------------
    def action_show_tab(self, key: str) -> None:
        self.query_one(Tabs).active = f"tab-{key}"

    def on_tabs_tab_activated(self, event: Tabs.TabActivated) -> None:
        if event.tab.id:
            self.query_one(ContentSwitcher).current = f"view-{event.tab.id.removeprefix('tab-')}"

    # --- status polling ---------------------------------------------------
    def poll(self) -> Worker:
        """Refresh the header in a thread worker; returns the worker (await `.wait()` in tests)."""
        self._poll_seq += 1
        return self.run_worker(
            lambda seq=self._poll_seq: self._fetch_status(seq),
            thread=True, exclusive=True, group="status")

    def _fetch_status(self, seq: int) -> None:
        try:
            health = self.api.health()
            gov = self.api.governance_status()
            silos = gov["silos"]
            host = urlparse(self.settings.kudzu_host).hostname or self.settings.kudzu_host
            state = ("empty ⚠" if silos.get("expertise", 0) == 0 else
                     f"{silos['expertise']}/{silos['rejection']}/{silos['contested']}")
            text = (f"Kudzu ── {host} ● {health['holograms']} holograms ── "
                    f"{gov['model']} ── silos: {state}")
        except KudzuAPIError as exc:
            text = f"Kudzu ── disconnected ✗ ({exc.code})"
        except (KeyError, TypeError, ValueError):
            text = "Kudzu ── disconnected ✗ (bad_response)"
        except Exception:  # never let an unexpected error kill the worker and the app
            text = "Kudzu ── disconnected ✗ (error)"
        if get_current_worker().is_cancelled:
            return
        try:
            # post_message is thread-safe and non-blocking; it drops the message if the app is gone.
            self.post_message(StatusResult(seq, text))
        except Exception:
            pass  # app shutting down: drop the result silently

    def on_status_result(self, message: StatusResult) -> None:
        if message.seq < self._applied_seq:
            return  # older poll finished after a newer one; never show stale status
        self._applied_seq = message.seq
        self.query_one("#status-header", Static).update(message.text)

    # --- footer -----------------------------------------------------------
    def notify_copy(self, path: str) -> None:
        """Show `copied (<path>)` in the footer, then restore the key hints."""
        self._show_footer(f"copied ({path})")

    def _show_footer(self, text: str) -> None:
        footer = self.query_one("#footer-hints", Static)
        footer.update(text)
        if self._copy_timer is not None:
            self._copy_timer.stop()
        self._copy_timer = self.set_timer(
            self.copy_notice_seconds, lambda: footer.update(FOOTER_HINTS))

    def notify_copy_failed(self) -> None:
        """Show how to fall back to the terminal's own selection, then restore the hints."""
        self._show_footer("copy failed — hold Shift and drag to use the terminal's selection")

    def on_text_selected(self, event: events.TextSelected) -> None:
        """Mouse released after a drag: copy the highlighted text (Shift+drag never reaches us)."""
        text = self.screen.get_selected_text()
        if text is None or not text.strip():
            return
        path = copy_text(self, text)
        if path == "none":
            self.notify_copy_failed()
        else:
            self.notify_copy(path)

    # --- palette ----------------------------------------------------------
    async def on_palette_command(self, message: PaletteCommand) -> None:
        """PaletteCommand never reaches the views, so hand it to the chat view."""
        await self.query_one(ChatView).run_command(message.name)

    def on_ledger_changed(self, message: LedgerChanged) -> None:
        """LedgerChanged never reaches the views, so forward it to the ledger view."""
        self.query_one(LedgerView).ledger_changed()

    def run_palette_command(self, name: str) -> None:
        if name == "quit":
            self.exit()
        else:
            self.post_message(PaletteCommand(name))


def main() -> None:
    settings = Settings.from_env()
    KudzuConsole(KudzuAPI(settings), settings).run()
