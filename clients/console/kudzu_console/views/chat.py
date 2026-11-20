"""Chat view: backend sidebar, selectable conversation, input with history."""
from __future__ import annotations

from textual import events
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Checkbox, Markdown, Static, TextArea

from ..background import run_in_background, wait_idle
from ..backends import BACKENDS, Event, PipelineResult, run_pipeline
from ..commands import run_command

WELCOME = ("Kudzu Chat. Space toggles a backend, Tab moves between sidebar and input, "
           "Enter sends, Shift+Enter adds a line.\nCommands: /status /progress /traces /clear /quit")
SLASH_COMMANDS = ("status", "progress", "traces")


class PipelineEvent(Message):
    def __init__(self, epoch: int, event: Event) -> None:
        super().__init__()
        self.epoch = epoch
        self.event = event


class PipelineFinished(Message):
    def __init__(self, epoch: int, result: PipelineResult) -> None:
        super().__init__()
        self.epoch = epoch
        self.result = result


class CommandOutput(Message):
    def __init__(self, epoch: int, text: str) -> None:
        super().__init__()
        self.epoch = epoch
        self.text = text


class ChatInput(TextArea):
    """Enter submits, Shift+Enter (or Ctrl+J) adds a line, Up/Down at the edges walk history."""

    class Submitted(Message):
        def __init__(self, text: str) -> None:
            super().__init__()
            self.text = text

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self.sent: list[str] = []
        self._pos = 0  # == len(history) while editing a fresh line
        self._draft = ""

    def remember(self, text: str) -> None:
        if text and (not self.sent or self.sent[-1] != text):
            self.sent.append(text)
        self._pos = len(self.sent)

    def _show(self, text: str) -> None:
        self.text = text
        self.move_cursor(self.document.end)

    async def _on_key(self, event: events.Key) -> None:
        key = event.key
        if key == "enter":
            event.stop()
            event.prevent_default()
            self.post_message(self.Submitted(self.text))
        elif key in ("shift+enter", "ctrl+j"):
            event.stop()
            event.prevent_default()
            start, end = self.selection
            self._replace_via_keyboard("\n", start, end)
        elif key == "up" and self.cursor_location[0] == 0 and self._pos > 0:
            event.stop()
            event.prevent_default()
            if self._pos == len(self.sent):
                self._draft = self.text
            self._pos -= 1
            self._show(self.sent[self._pos])
        elif key == "down" and self._pos < len(self.sent) \
                and self.cursor_location[0] == self.document.line_count - 1:
            event.stop()
            event.prevent_default()
            self._pos += 1
            self._show(self._draft if self._pos == len(self.sent) else self.sent[self._pos])
        else:
            await super()._on_key(event)


class ChatView(Widget):
    """Conversation entries are Static / Markdown widgets so highlight-to-copy can select them."""

    def __init__(self, api, settings) -> None:
        super().__init__(id="view-chat")
        self.api = api
        self.settings = settings
        self._epoch = 0  # bumped by /clear so output from before it is dropped
        self._busy = False
        self._open: dict[str, tuple[Markdown, str]] = {}  # backend label -> (widget, text so far)

    def compose(self) -> ComposeResult:
        with Vertical(id="chat-sidebar"):
            yield Static("Backends", id="chat-sidebar-title")
            with VerticalScroll(id="backends"):
                for i, b in enumerate(BACKENDS):
                    yield Checkbox(b.label, b.default_on, id=f"backend-{i}", compact=True)
            yield Static(self._meta_text(None, 0, 0.0), id="chat-meta", markup=False)
        with Vertical(id="chat-main"):
            with VerticalScroll(id="conversation"):
                yield Static(WELCOME, classes="welcome", markup=False)
            yield ChatInput(id="chat-input")

    # --- public helpers ---------------------------------------------------
    def enabled_backends(self) -> list[str]:
        return [b.key for i, b in enumerate(BACKENDS) if self.query_one(f"#backend-{i}", Checkbox).value]

    def conversation_text(self) -> str:
        """Plain text of the conversation (welcome note excluded)."""
        parts = []
        for w in self.query_one("#conversation").children:
            if "welcome" in w.classes:
                continue
            parts.append(w.source if isinstance(w, Markdown) else str(w.render()))
        return "\n".join(parts)

    async def wait_idle(self) -> None:
        await wait_idle(self)

    async def run_command(self, name: str, args: list[str] | None = None) -> None:
        """Palette / slash entry point for clear, status, progress, traces."""
        if name == "clear":
            await self._clear()
        elif name in SLASH_COMMANDS:
            epoch = self._epoch
            run_in_background(self, lambda: self._command_worker(epoch, name, args or []),
                              name="kudzu-command")

    # --- input ------------------------------------------------------------
    @staticmethod
    def _meta_text(tier: int | None, tools: int, cost: float) -> str:
        return f"tier {tier if tier is not None else '—'} · {tools} tools · ${cost:.2f}"

    async def on_chat_input_submitted(self, message: ChatInput.Submitted) -> None:
        text = message.text.strip()
        if not text:
            return
        inp = self.query_one("#chat-input", ChatInput)
        if text.startswith("/"):
            inp.remember(text)
            inp.text = ""
            await self._slash(text)
            return
        if self._busy:
            await self._add(Static("! still answering the previous message; try again in a moment",
                             classes="note", markup=False))
            return
        inp.remember(text)
        inp.text = ""
        self._busy = True
        self._open = {}
        await self._add(Static(f"You: {text}", classes="user", markup=False))
        enabled = self.enabled_backends()
        epoch = self._epoch
        run_in_background(self, lambda: self._pipeline_worker(epoch, text, enabled), name="kudzu-pipeline")

    async def _slash(self, text: str) -> None:
        parts = text.split()
        name = parts[0][1:].lower()
        if name in ("quit", "exit"):
            self.app.exit()
        elif name == "clear" or name in SLASH_COMMANDS:
            await self.run_command(name, parts[1:])
        else:
            await self._add(Static(f"Unknown command: /{name}. Try /status /progress /traces /clear /quit",
                             classes="note", markup=False))

    # --- background threads -------------------------------------------------
    def _post(self, message: Message) -> None:
        try:
            self.post_message(message)  # thread-safe; dropped if the app is going away
        except Exception:
            pass

    def _pipeline_worker(self, epoch: int, message: str, enabled: list[str]) -> None:
        def on_event(ev: Event) -> None:
            self._post(PipelineEvent(epoch, ev))
        try:
            result = run_pipeline(message, enabled, self.settings, on_event)
        except Exception as exc:  # never let a worker error kill the app
            on_event(Event("Pipeline", "error", f"{type(exc).__name__}: {exc}"))
            result = PipelineResult()
        self._post(PipelineFinished(epoch, result))

    def _command_worker(self, epoch: int, name: str, args: list[str]) -> None:
        try:
            text = run_command(name, self.settings, args)
        except Exception as exc:
            text = f"{name} error: {exc}"
        if epoch != self._epoch:
            return  # cleared meanwhile
        self._post(CommandOutput(epoch, text))

    # --- results (UI thread) ----------------------------------------------
    async def on_pipeline_event(self, message: PipelineEvent) -> None:
        if message.epoch != self._epoch:
            return
        ev = message.event
        if ev.kind == "chunk":
            await self._append_chunk(ev.backend, ev.text)
        elif ev.kind == "error":
            await self._add(Static(f"✗ [{ev.backend}] {ev.text}", classes="error", markup=False))
        else:
            await self._add(Static(f"  {ev.text}", classes="status", markup=False))

    def on_pipeline_finished(self, message: PipelineFinished) -> None:
        self._busy = False
        r = message.result
        self.query_one("#chat-meta", Static).update(
            self._meta_text(r.tier, len(r.tool_calls), r.cost_usd))

    async def on_command_output(self, message: CommandOutput) -> None:
        if message.epoch == self._epoch:
            await self._add(Static(message.text, classes="command", markup=False))

    async def _append_chunk(self, backend: str, text: str) -> None:
        entry = self._open.get(backend)
        if entry is None:
            await self._add(Static(f"[{backend}]", classes="label", markup=False))
            md = Markdown("")
            await self._add(md)
            entry = (md, "")
        md, so_far = entry
        so_far += text
        self._open[backend] = (md, so_far)
        await md.update(so_far)
        self._scroll_end()

    async def _add(self, widget: Widget) -> None:
        await self.query_one("#conversation").mount(widget)
        self._scroll_end()

    def _scroll_end(self) -> None:
        self.query_one("#conversation").scroll_end(animate=False)

    async def _clear(self) -> None:
        self._epoch += 1
        self._open = {}
        await self.query_one("#conversation").remove_children()
