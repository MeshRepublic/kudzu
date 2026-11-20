"""Antitrust view (placeholder; filled in by a later task)."""
from __future__ import annotations

from textual.app import ComposeResult
from textual.widget import Widget
from textual.widgets import Static


class AntitrustView(Widget):
    def __init__(self, api, settings) -> None:
        super().__init__(id="view-antitrust")
        self.api = api
        self.settings = settings

    def compose(self) -> ComposeResult:
        yield Static("Antitrust view")
