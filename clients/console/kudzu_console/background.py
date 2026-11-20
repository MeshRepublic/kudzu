"""The one way the console starts blocking work: a daemon thread per call.

Textual thread workers run on the event loop's default executor, and `App.run()` waits for
those threads before it returns, so quitting would block on any network call in flight.
Daemon threads never hold up the exit.

Callers keep their own guarantees: the callable catches its own errors, hands its result to
the UI only through `post_message` (which drops it once the app or view has gone), and
tags it with a sequence/epoch number so a stale result is ignored. Daemon threads cannot be
cancelled; those sequence numbers are what make an abandoned call harmless.
"""
from __future__ import annotations

import asyncio
import contextvars
import threading
from typing import Callable

_JOBS_ATTR = "_background_jobs"


class Job:
    """Handle to one background call; tests await `wait()`."""

    def __init__(self, thread: threading.Thread) -> None:
        self._thread = thread

    def is_alive(self) -> bool:
        return self._thread.is_alive()

    def join(self, timeout: float | None = None) -> None:
        self._thread.join(timeout)

    async def wait(self) -> None:
        """Wait, without blocking the event loop, until the call has returned."""
        while self._thread.is_alive():
            await asyncio.sleep(0.005)


def run_in_background(owner: object, fn: Callable[[], None], *, name: str = "kudzu-background") -> Job:
    """Run `fn` in a daemon thread and remember the job on `owner` (see `wait_idle`)."""
    ctx = contextvars.copy_context()  # keeps Textual's active app visible to post_message

    def target() -> None:
        try:
            ctx.run(fn)
        except Exception:  # call sites catch their own errors; never let one escape the thread
            pass

    thread = threading.Thread(target=target, name=name, daemon=True)
    job = Job(thread)
    jobs = [j for j in getattr(owner, _JOBS_ATTR, []) if j.is_alive()]
    jobs.append(job)
    setattr(owner, _JOBS_ATTR, jobs)
    thread.start()
    return job


async def wait_idle(owner: object) -> None:
    """Wait for every background call `owner` had started when this was called."""
    for job in list(getattr(owner, _JOBS_ATTR, [])):
        await job.wait()
