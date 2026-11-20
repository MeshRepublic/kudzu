import threading

import pytest
from textual.widgets import Checkbox, Static

from kudzu_console.app import KudzuConsole
from kudzu_console.backends import BACKENDS, Event, PipelineResult
from kudzu_console.views import chat as chat_mod
from test_app import FakeAPI, SETTINGS


class ChatConsole(KudzuConsole):
    def __init__(self):
        super().__init__(FakeAPI(), SETTINGS, poll_interval=3600, copy_notice_seconds=30)
        self.clipboard_log = []

    def copy_to_clipboard(self, text):
        self.clipboard_log.append(text)


class Stub:
    """Replaces run_pipeline: records calls, emits scripted events, returns a result."""

    def __init__(self, events=(), result=None, gate=None):
        self.calls = []
        self.events = list(events)
        self.result = result or PipelineResult(tier=2, tool_calls=[], cost_usd=0.0)
        self.gate = gate
        self.threads = []

    def __call__(self, message, enabled, settings, on_event):
        self.calls.append((message, list(enabled)))
        self.threads.append(threading.current_thread())
        for ev in self.events:
            on_event(ev)
        if self.gate:
            self.gate.wait(5)
        return self.result


@pytest.fixture
def stub(monkeypatch):
    s = Stub([Event("Kudzu Brain", "chunk", "hello from the brain")])
    monkeypatch.setattr(chat_mod, "run_pipeline", s)
    return s


@pytest.fixture(autouse=True)
def no_network_commands(monkeypatch):
    def fake(name, settings, args=None):
        return f"[{name}] output {args}"
    monkeypatch.setattr(chat_mod, "run_command", fake)


def log_text(app):
    return app.query_one("#view-chat").conversation_text()


async def send(app, pilot, text):
    app.query_one("#chat-input").focus()
    await pilot.press(*text)
    await pilot.press("enter")
    await app.query_one("#view-chat").wait_idle()
    await pilot.pause()


async def test_enter_sends_and_shows_message(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "hi")
        assert "You: hi" in log_text(app)
        assert stub.calls == [("hi", ["kudzu"])]
        assert app.query_one("#chat-input").text == ""


async def test_events_rendered_labelled_by_backend(monkeypatch):
    s = Stub([Event("Kudzu Brain", "chunk", "alpha "), Event("Kudzu Brain", "chunk", "beta"),
              Event("Web (SearXNG)", "error", "SearXNG not available (port 8888)."),
              Event("Claude API", "status", "thinking")])
    monkeypatch.setattr(chat_mod, "run_pipeline", s)
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "q")
        text = log_text(app)
        assert "[Kudzu Brain]" in text and "alpha beta" in text
        assert "✗ [Web (SearXNG)] SearXNG not available (port 8888)." in text
        assert "thinking" in text


async def test_pipeline_runs_in_worker_thread(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "q")
        assert stub.threads[0] is not threading.main_thread()


async def test_input_usable_while_streaming(monkeypatch):
    gate = threading.Event()
    s = Stub([Event("Kudzu Brain", "chunk", "partial")], gate=gate)
    monkeypatch.setattr(chat_mod, "run_pipeline", s)
    app = ChatConsole()
    async with app.run_test() as pilot:
        app.query_one("#chat-input").focus()
        await pilot.press("a", "enter")
        await pilot.pause()
        await pilot.press("x", "y")
        await pilot.pause()
        assert app.query_one("#chat-input").text == "xy"
        assert "partial" in log_text(app)  # streamed text visible before the pipeline finished
        gate.set()
        await app.query_one("#view-chat").wait_idle()


async def test_clicking_checkbox_changes_enabled_list(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        web = next(i for i, b in enumerate(BACKENDS) if b.key == "web")
        await pilot.click(f"#backend-{web}")
        await pilot.pause()
        await send(app, pilot, "q")
        assert stub.calls[0][1] == ["kudzu", "web"]


async def test_space_toggles_focused_checkbox(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        cb = app.query_one("#backend-1", Checkbox)
        cb.focus()
        await pilot.press("space")
        await pilot.pause()
        assert cb.value is True
        assert app.query_one("#view-chat").enabled_backends() == ["kudzu", BACKENDS[1].key]


async def test_tab_moves_between_sidebar_and_input(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        seen = set()
        for _ in range(len(BACKENDS) + 3):
            await pilot.press("tab")
            seen.add(app.focused.id if app.focused else None)
        assert "chat-input" in seen and "backend-0" in seen


async def test_meta_line(monkeypatch):
    s = Stub([], PipelineResult(tier=2, tool_calls=[], cost_usd=0.0))
    monkeypatch.setattr(chat_mod, "run_pipeline", s)
    app = ChatConsole()
    async with app.run_test() as pilot:
        meta = app.query_one("#chat-meta")
        assert str(meta.render()) == "tier — · 0 tools · $0.00"
        await send(app, pilot, "q")
        assert str(meta.render()) == "tier 2 · 0 tools · $0.00"
        s.result = PipelineResult(tier=None, tool_calls=["a", "b"], cost_usd=0.0)
        await send(app, pilot, "again")
        assert str(meta.render()) == "tier — · 2 tools · $0.00"
        s.result = PipelineResult(tier=3, tool_calls=["a"], cost_usd=0.126)
        await send(app, pilot, "more")
        assert str(meta.render()) == "tier 3 · 1 tools · $0.13"


async def test_palette_clear_empties_log(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "hello")
        assert log_text(app)
        app.run_palette_command("clear")
        await pilot.pause()
        assert log_text(app) == ""


async def test_palette_status_prints_into_conversation(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        app.run_palette_command("status")
        await app.query_one("#view-chat").wait_idle()
        await pilot.pause()
        assert "[status] output []" in log_text(app)


async def test_slash_commands(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "/traces thought 3")
        assert "[traces] output ['thought', '3']" in log_text(app)
        assert not stub.calls  # not sent to the pipeline
        await send(app, pilot, "/clear")
        assert log_text(app) == ""
        await send(app, pilot, "/bogus")
        assert "Unknown command: /bogus" in log_text(app)


async def test_slash_quit_exits(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "/quit")
        await pilot.pause()
    assert app.return_code is not None or not app.is_running


async def test_shift_enter_newline_and_history(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        inp = app.query_one("#chat-input")
        inp.focus()
        await pilot.press("a", "shift+enter", "b")
        assert inp.text == "a\nb"
        inp.text = ""
        await send(app, pilot, "one")
        await send(app, pilot, "two")
        await pilot.press("up")
        assert inp.text == "two"
        await pilot.press("up")
        assert inp.text == "one"
        await pilot.press("down")
        assert inp.text == "two"
        await pilot.press("down")
        assert inp.text == ""


async def test_drag_across_message_copies_text(monkeypatch):
    s = Stub([Event("Kudzu Brain", "chunk", "selectable answer text")])
    monkeypatch.setattr(chat_mod, "run_pipeline", s)
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "q")
        para = app.query_one("#conversation MarkdownParagraph")
        await pilot.mouse_down(para, offset=(0, 0))
        await pilot.hover(para, offset=(9, 0))
        await pilot.mouse_up(para, offset=(9, 0))
        await pilot.pause()
        assert app.clipboard_log == ["selectable"]


async def test_narrow_stacks_sidebar_above_conversation(stub):
    app = ChatConsole()
    async with app.run_test(size=(70, 24)) as pilot:
        await pilot.pause()
        assert app.has_class("narrow")
        side = app.query_one("#chat-sidebar").region
        conv = app.query_one("#conversation").region
        assert side.bottom <= conv.y
    app = ChatConsole()
    async with app.run_test(size=(120, 30)) as pilot:
        await pilot.pause()
        assert app.query_one("#chat-sidebar").region.right <= app.query_one("#conversation").region.x


async def test_worker_error_never_crashes(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("kaboom")
    monkeypatch.setattr(chat_mod, "run_pipeline", boom)
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "q")
        assert "kaboom" in log_text(app)
        await send(app, pilot, "again")  # still alive and not stuck busy
        assert log_text(app).count("You:") == 2


async def test_palette_clear_works_from_another_tab(stub):
    app = ChatConsole()
    async with app.run_test() as pilot:
        await send(app, pilot, "hello")
        await pilot.press("f4")
        await pilot.pause()
        assert app.query_one("#view-ledger").display
        app.run_palette_command("clear")
        await pilot.pause()
        assert log_text(app) == ""
