"""Clipboard writes: OSC 52 through the terminal, with a local-program fallback."""
from __future__ import annotations

import os
import shutil
import subprocess

LOCAL_COMMANDS = (
    ["wl-copy"],
    ["xclip", "-selection", "clipboard"],
    ["pbcopy"],
)
LOCAL_TIMEOUT = 2  # seconds; a clipboard helper must never stall the UI


def _copy_local(text: str) -> bool:
    for cmd in LOCAL_COMMANDS:
        if shutil.which(cmd[0]):
            try:
                done = subprocess.run(cmd, input=text.encode("utf-8"), timeout=LOCAL_TIMEOUT,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:  # timeout, OSError, anything: report failure, never raise
                return False
            return done.returncode == 0
    return False


def copy_text(app, text: str) -> str:
    """Copy `text`; return "osc52", "local" or "none". Never raises.

    OSC 52 support cannot be detected from inside the app, so it is assumed unless
    KUDZU_CLIPBOARD=local is set or the call itself raises.
    """
    if os.environ.get("KUDZU_CLIPBOARD") != "local":
        try:
            app.copy_to_clipboard(text)
            return "osc52"
        except Exception:
            pass
    return "local" if _copy_local(text) else "none"
