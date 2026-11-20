"""Ledger view: read-only weight totals per principle and the ledger entries."""
from __future__ import annotations

from textual import events
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Static
from textual.worker import get_current_worker

from ..api import KudzuAPIError
from . import ledger_format as fmt

NARROW_WIDTH = 80  # same breakpoint as the App's `narrow` class


class LedgerLoaded(Message):
    def __init__(self, seq: int, parsed, error: str | None) -> None:
        super().__init__()
        self.seq = seq
        self.parsed = parsed  # (entries, totals, tau_a) or None
        self.error = error


class Cell(Static, can_focus=True):
    """A focusable, clickable header or total; Enter/Space/click activate it."""

    BINDINGS = [Binding("enter", "activate", "Activate", show=False),
                Binding("space", "activate", "Activate", show=False)]

    class Activated(Message):
        def __init__(self, kind: str, key: str) -> None:
            super().__init__()
            self.kind = kind
            self.key = key

    def __init__(self, text: str, kind: str, key: str, **kw) -> None:
        super().__init__(text, markup=False, **kw)
        self.kind = kind
        self.key = key

    def action_activate(self) -> None:
        self.post_message(self.Activated(self.kind, self.key))

    def on_click(self, event: events.Click) -> None:
        self.action_activate()


class LedgerView(Widget):
    def __init__(self, api, settings) -> None:
        super().__init__(id="view-ledger")
        self.api = api
        self.settings = settings
        self._seq = 0
        self._data: tuple[list[dict], dict[str, float], float] | None = None
        self._sort_key: str | None = None
        self._descending = False
        self._filter: str | None = None
        self._narrow = False

    def compose(self) -> ComposeResult:
        yield Static("", id="ledger-message", markup=False)
        yield Vertical(id="totals")
        with Vertical(id="entries"):
            with Horizontal(id="entries-head"):
                for key, label in fmt.COLUMNS:
                    yield Cell(label, "sort", key, id=f"head-{key}", classes="head")
            yield VerticalScroll(id="entries-rows")

    # --- loading ----------------------------------------------------------
    def on_show(self, event: events.Show) -> None:
        self.refresh_ledger()

    def refresh_ledger(self) -> None:
        """Load the ledger in a thread worker (one `api.ledger()` call per call)."""
        self._seq += 1
        seq = self._seq
        self.run_worker(lambda: self._load(seq), thread=True, exclusive=True, group="ledger")

    def ledger_changed(self) -> None:
        """A vote was recorded. A hidden view refreshes when shown, so only a shown one loads now."""
        if self.display:
            self.refresh_ledger()

    def _load(self, seq: int) -> None:
        parsed = error = None
        try:
            parsed = fmt.parse_ledger(self.api.ledger())
            if parsed is None:
                error = "bad_response"
        except KudzuAPIError as exc:
            error = exc.code
        except Exception:
            error = "error"
        if get_current_worker().is_cancelled:
            return
        try:
            self.post_message(LedgerLoaded(seq, parsed, error))
        except Exception:
            pass  # app shutting down

    async def on_ledger_loaded(self, message: LedgerLoaded) -> None:
        if message.seq != self._seq:
            return  # a newer load is in flight; never show an older result
        self._data = message.parsed
        note = self.query_one("#ledger-message", Static)
        if self._data is None:
            note.update(f"✗ could not load ledger: {message.error}")
        else:
            entries, totals, _ = self._data
            note.update(fmt.EMPTY_TEXT if not entries else "")
            if self._filter not in totals:
                self._filter = None
        await self._render_totals()
        await self._render_rows()

    # --- activation -------------------------------------------------------
    async def on_cell_activated(self, message: Cell.Activated) -> None:
        message.stop()
        if message.kind == "sort":
            if self._sort_key == message.key:
                self._descending = not self._descending
            else:
                self._sort_key, self._descending = message.key, False
        else:
            self._filter = None if self._filter == message.key else message.key
            for cell in self.query("#totals Cell").results(Cell):
                cell.set_class(cell.key == self._filter, "active")
        await self._render_rows()

    async def on_resize(self, event: events.Resize) -> None:
        self._fit_totals()
        narrow = event.size.width < NARROW_WIDTH
        if narrow != self._narrow:
            self._narrow = narrow
            await self._render_rows()

    # --- rendering --------------------------------------------------------
    async def _render_totals(self) -> None:
        box = self.query_one("#totals", Vertical)
        await box.remove_children()
        if self._data is None:
            return
        _, totals, tau = self._data
        cells = []
        for principle in fmt.ordered_principles(totals, tau):
            cell = Cell(fmt.total_label(principle, totals[principle], tau), "filter", principle, classes="total")
            cell.set_class(fmt.is_over(totals[principle], tau), "over")
            cell.set_class(principle == self._filter, "active")
            cells.append(cell)
        await box.mount_all(cells)
        self._fit_totals()

    def _fit_totals(self) -> None:
        """Wrapping grid: as many equal columns as fit the width (at least one)."""
        if self._data is None or not self._data[1]:
            return
        _, totals, tau = self._data
        cell_w = max(len(fmt.total_label(p, totals[p], tau)) for p in totals) + 2  # cell padding
        gutter = 2
        avail = max(self.size.width - 2 - 2, 1)  # view padding, scrollbar
        cols = max(1, (avail + gutter) // (cell_w + gutter))
        self.query_one("#totals", Vertical).styles.grid_size_columns = cols

    async def _render_rows(self) -> None:
        cols = fmt.columns(self._narrow)
        shown = {key for key, _ in cols}
        entries = []
        if self._data is not None:
            entries = fmt.sort_entries(fmt.filter_entries(self._data[0], self._filter),
                                       self._sort_key, self._descending)
        widths = fmt.column_widths(entries, cols)
        for key, label in fmt.COLUMNS:
            head = self.query_one(f"#head-{key}", Cell)
            head.display = key in shown
            head.update(fmt.header_label(key, label, self._sort_key, self._descending))
            if key in widths:
                head.styles.width = widths[key]
        rows = self.query_one("#entries-rows", VerticalScroll)
        await rows.remove_children()
        await rows.mount_all(Static(fmt.row_text(e, cols, widths), markup=False, classes="row") for e in entries)
