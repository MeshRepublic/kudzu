"""Ledger view (placeholder; filled in by a later task)."""
from __future__ import annotations

from textual.app import ComposeResult
from textual.widget import Widget
from textual.widgets import Static


class LedgerView(Widget):
    def __init__(self, api, settings) -> None:
        super().__init__(id="view-ledger")
        self.api = api
        self.settings = settings

    def compose(self) -> ComposeResult:
        yield Static("Ledger view")
