"""Antitrust view: try the Antitrust 2.0 rule on a scenario; the server decides."""
from __future__ import annotations

from textual import events
from textual.app import ComposeResult
from textual.containers import Grid, Horizontal, VerticalScroll
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Button, Input, Label, Static
from textual.worker import get_current_worker

from ..api import KudzuAPIError
from ..presets import PRESETS
from . import antitrust_format as fmt

EVALUATE_LABEL = "Evaluate"
EVALUATING_LABEL = "evaluating…"
DEFAULTS_NOTE = "! defaults could not be confirmed with the server"
FIELDS = [("company", "Company"), ("vertical", "Vertical"), ("share", "Market share %"),
          ("baseline", "Baseline sat."), ("current", "Current sat."),
          ("th-share", "Share limit %"), ("th-drop", "Drop limit %")]
NUMERIC = ("share", "baseline", "current", "th-share", "th-drop")
PRESET_FIELDS = {"company": "company", "vertical": "vertical", "share": "market_share",
                 "baseline": "baseline_satisfaction", "current": "current_satisfaction"}


class DefaultsLoaded(Message):
    def __init__(self, defaults: dict | None) -> None:
        super().__init__()
        self.defaults = defaults


class AntitrustEvaluated(Message):
    def __init__(self, seq: int, text: str | None, error: KudzuAPIError | str | None) -> None:
        super().__init__()
        self.seq = seq
        self.text = text
        self.error = error


class AntitrustView(Widget):
    def __init__(self, api, settings) -> None:
        super().__init__(id="view-antitrust")
        self.api = api
        self.settings = settings
        self._defaults_ok = False
        self._loading = False
        self._busy = False
        self._seq = 0
        self._pending_values: dict[str, str] = {}
        self._shown_values: dict[str, str] | None = None  # inputs the displayed result was computed from

    def compose(self) -> ComposeResult:
        with Horizontal(id="antitrust-body"):
            with VerticalScroll(id="scenario"):
                yield Label("Presets", id="presets-title")
                with Grid(id="presets"):
                    for i, preset in enumerate(PRESETS):
                        yield Button(preset["label"], id=f"preset-{i}", compact=True)
                for fid, label in FIELDS:
                    with Horizontal(classes="field-row"):
                        yield Label(label, classes="field-label")
                        initial = str(fmt.DEFAULT_SHARE) if fid == "th-share" else str(fmt.DEFAULT_DROP) if fid == "th-drop" else ""
                        yield Input(value=initial, id=fid, compact=True)
                        yield Static("", id=f"err-{fid}", classes="field-error", markup=False)
                yield Static("", id="defaults-note", markup=False)
                yield Button(EVALUATE_LABEL, id="evaluate")
                yield Static("", id="message", markup=False)
            with VerticalScroll(id="result-panel"):
                yield Static("", id="result", markup=False)

    def on_show(self, event: events.Show) -> None:
        if not self._defaults_ok:
            self._load_defaults()  # first show loads; a later show retries a failed load

    def _post(self, message: Message) -> None:
        try:
            self.post_message(message)
        except Exception:
            pass

    # --- defaults ---------------------------------------------------------
    def _load_defaults(self) -> None:
        if self._loading:
            return
        self._loading = True
        self.run_worker(self._defaults_worker, thread=True, group="defaults")

    def _defaults_worker(self) -> None:
        try:
            d = self.api.governance_status()["antitrust_defaults"]
            defaults = {"share": fmt.num(float(d["share"])), "satisfaction_drop": fmt.num(float(d["satisfaction_drop"]))}
        except Exception:
            defaults = None
        if get_current_worker().is_cancelled:
            return
        self._post(DefaultsLoaded(defaults))

    def on_defaults_loaded(self, message: DefaultsLoaded) -> None:
        self._loading = False
        note = self.query_one("#defaults-note", Static)
        if message.defaults is None:
            self._defaults_ok = False
            note.update(DEFAULTS_NOTE)
            return
        self._defaults_ok = True
        note.update("")
        share, drop = self.query_one("#th-share", Input), self.query_one("#th-drop", Input)
        # only replace the prefill if the user has not edited the limits meanwhile
        if share.value == str(fmt.DEFAULT_SHARE) and drop.value == str(fmt.DEFAULT_DROP):
            share.value, drop.value = message.defaults["share"], message.defaults["satisfaction_drop"]

    # --- inputs -----------------------------------------------------------
    def _values(self) -> dict[str, str]:
        return {fid: self.query_one(f"#{fid}", Input).value for fid, _ in FIELDS}

    def _set_error(self, fid: str, text: str) -> None:
        self.query_one(f"#err-{fid}", Static).update(text)
        self.query_one(f"#{fid}", Input).set_class(bool(text), "invalid")

    def _clear_errors(self) -> None:
        for fid, _ in FIELDS:
            self._set_error(fid, "")
        self.query_one("#message", Static).update("")

    def _clear_result(self) -> None:
        self._shown_values = None
        self.query_one("#result", Static).update("")

    def on_input_changed(self, event: Input.Changed) -> None:
        event.stop()
        fid = event.input.id
        if event.input.has_class("invalid"):
            self._set_error(fid, "")
        if self._shown_values is not None and self._values() != self._shown_values:
            self._clear_result()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        event.stop()
        self._start_evaluate()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        event.stop()
        bid = event.button.id or ""
        if bid == "evaluate":
            self._start_evaluate()
        elif bid.startswith("preset-"):
            self._apply_preset(PRESETS[int(bid.split("-")[1])])

    def _apply_preset(self, preset: dict) -> None:
        self._clear_errors()
        self._clear_result()
        for fid, key in PRESET_FIELDS.items():
            self.query_one(f"#{fid}", Input).value = str(preset[key])

    # --- evaluate ---------------------------------------------------------
    def _start_evaluate(self) -> None:
        if self._busy:
            return
        self._clear_result()
        self._clear_errors()
        values = self._values()
        body, errors = fmt.validate(values)
        if body is None:
            for fid, text in errors.items():
                self._set_error(fid, text)
            self.query_one(f"#{next(iter(errors))}", Input).focus()
            return
        self._busy = True
        self._seq += 1
        self._pending_values = values
        button = self.query_one("#evaluate", Button)
        button.label = EVALUATING_LABEL
        button.disabled = True
        seq = self._seq
        self.run_worker(lambda: self._evaluate_worker(seq, body), thread=True, group="evaluate")

    def _evaluate_worker(self, seq: int, body: dict) -> None:
        text = error = None
        try:
            text = fmt.result_text(self.api.evaluate_antitrust(body))
            if text is None:
                error = "bad_response"
        except KudzuAPIError as exc:
            error = exc
        except Exception:
            error = "bad_response"
        if get_current_worker().is_cancelled:
            return
        self._post(AntitrustEvaluated(seq, text, error))

    def on_antitrust_evaluated(self, message: AntitrustEvaluated) -> None:
        if message.seq != self._seq:
            return
        self._busy = False
        button = self.query_one("#evaluate", Button)
        button.label = EVALUATE_LABEL
        button.disabled = False
        if self._values() != self._pending_values:
            return  # inputs were edited while in flight; the result no longer matches them
        if message.text is not None:
            self._shown_values = self._pending_values
            self.query_one("#result", Static).update(message.text)
            return
        err = message.error
        message_widget = self.query_one("#message", Static)
        if isinstance(err, KudzuAPIError) and err.status == 422 and err.code == "invalid":
            fid = fmt.FIELD_IDS.get(str((err.detail or {}).get("field")))
            if fid is not None:
                self._set_error(fid, "rejected by server")
                return
            message_widget.update(f"✗ scenario rejected by server: {(err.detail or {}).get('field', 'invalid')}")
        elif isinstance(err, KudzuAPIError):
            message_widget.update("✗ server unreachable" if err.code == "unreachable" else f"✗ evaluation failed: {err.code}")
        else:
            message_widget.update(f"✗ evaluation failed: {err}")
