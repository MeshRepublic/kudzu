import subprocess

import pytest
from textual.widgets import Static, Tabs

from kudzu_console import clipboard
from kudzu_console.app import KudzuConsole
from kudzu_console.clipboard import copy_text
from kudzu_console.config import Settings
from test_app import FakeAPI, SETTINGS


class FakeApp:
    def __init__(self, fail=False):
        self.copied = []
        self.fail = fail

    def copy_to_clipboard(self, text):
        if self.fail:
            raise RuntimeError("no osc52")
        self.copied.append(text)


@pytest.fixture(autouse=True)
def _no_real_clipboard(monkeypatch):
    monkeypatch.delenv("KUDZU_CLIPBOARD", raising=False)
    monkeypatch.setattr(clipboard.shutil, "which", lambda name: None)

    def boom(*a, **kw):
        raise AssertionError("real subprocess spawned")
    monkeypatch.setattr(clipboard.subprocess, "run", boom)


def fake_which(only):
    return lambda name: f"/usr/bin/{name}" if name == only else None


def test_osc52_path():
    app = FakeApp()
    assert copy_text(app, "héllo\nworld") == "osc52"
    assert app.copied == ["héllo\nworld"]


def test_local_xclip_gets_text_on_stdin(monkeypatch):
    monkeypatch.setenv("KUDZU_CLIPBOARD", "local")
    monkeypatch.setattr(clipboard.shutil, "which", fake_which("xclip"))
    calls = []

    def run(cmd, **kw):
        calls.append((cmd, kw))
        return subprocess.CompletedProcess(cmd, 0)
    monkeypatch.setattr(clipboard.subprocess, "run", run)
    app = FakeApp()
    assert copy_text(app, "abc") == "local"
    assert app.copied == []
    cmd, kw = calls[0]
    assert cmd == ["xclip", "-selection", "clipboard"]
    assert kw["input"] == b"abc"
    assert kw["timeout"] == 2


def test_osc52_failure_falls_back_to_local(monkeypatch):
    monkeypatch.setattr(clipboard.shutil, "which", fake_which("wl-copy"))
    monkeypatch.setattr(clipboard.subprocess, "run",
                        lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0))
    assert copy_text(FakeApp(fail=True), "x") == "local"


def test_none_when_nothing_available(monkeypatch):
    monkeypatch.setenv("KUDZU_CLIPBOARD", "local")
    assert copy_text(FakeApp(), "x") == "none"
    assert copy_text(FakeApp(fail=True), "x") == "none"


@pytest.mark.parametrize("exc", [subprocess.TimeoutExpired("xclip", 2), OSError("gone")])
def test_local_failure_never_raises(monkeypatch, exc):
    monkeypatch.setenv("KUDZU_CLIPBOARD", "local")
    monkeypatch.setattr(clipboard.shutil, "which", fake_which("xclip"))

    def run(cmd, **kw):
        raise exc
    monkeypatch.setattr(clipboard.subprocess, "run", run)
    assert copy_text(FakeApp(), "x") == "none"


def test_local_nonzero_exit_is_none(monkeypatch):
    monkeypatch.setenv("KUDZU_CLIPBOARD", "local")
    monkeypatch.setattr(clipboard.shutil, "which", fake_which("pbcopy"))
    monkeypatch.setattr(clipboard.subprocess, "run",
                        lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1))
    assert copy_text(FakeApp(), "x") == "none"


class CopyConsole(KudzuConsole):
    def __init__(self):
        super().__init__(FakeAPI(), SETTINGS, poll_interval=3600, copy_notice_seconds=30)
        self.clipboard_log = []

    def copy_to_clipboard(self, text):
        self.clipboard_log.append(text)


def footer(app):
    return str(app.query_one("#footer-hints").render())


async def test_drag_selects_and_release_copies():
    app = CopyConsole()
    async with app.run_test() as pilot:
        await app.query_one("#view-chat").mount(Static("hello world", id="probe", markup=False))
        await pilot.pause()
        await pilot.mouse_down("#probe", offset=(0, 0))
        await pilot.hover("#probe", offset=(4, 0))
        await pilot.mouse_up("#probe", offset=(4, 0))
        await pilot.pause()
        assert app.screen.get_selected_text() == "hello"
        assert app.clipboard_log == ["hello"]
        assert footer(app) == "copied (osc52)"


async def test_release_without_selection_copies_nothing():
    app = CopyConsole()
    async with app.run_test() as pilot:
        await pilot.click("#view-chat")
        await pilot.pause()
        assert app.clipboard_log == []
        assert footer(app).startswith("F1 Chat")


async def test_whitespace_only_selection_copies_nothing():
    app = CopyConsole()
    async with app.run_test() as pilot:
        await app.query_one("#view-chat").mount(Static("a     b", id="probe", markup=False))
        await pilot.pause()
        await pilot.mouse_down("#probe", offset=(2, 0))
        await pilot.hover("#probe", offset=(3, 0))
        await pilot.mouse_up("#probe", offset=(3, 0))
        await pilot.pause()
        assert app.clipboard_log == []


async def test_failed_copy_shows_shift_drag_hint(monkeypatch):
    monkeypatch.setenv("KUDZU_CLIPBOARD", "local")
    app = CopyConsole()
    async with app.run_test() as pilot:
        await app.query_one("#view-chat").mount(Static("hello world", id="probe", markup=False))
        await pilot.pause()
        await pilot.mouse_down("#probe", offset=(0, 0))
        await pilot.hover("#probe", offset=(4, 0))
        await pilot.mouse_up("#probe", offset=(4, 0))
        await pilot.pause()
        assert footer(app) == "copy failed — hold Shift and drag to use the terminal's selection"


async def test_tab_click_still_works_after_hook():
    app = CopyConsole()
    async with app.run_test() as pilot:
        await pilot.click("#tab-ledger")
        await pilot.pause()
        assert app.query_one(Tabs).active == "tab-ledger"
