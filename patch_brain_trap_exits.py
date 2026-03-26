#!/usr/bin/env python3
"""Fix Brain crash from linked Task.async in activity handlers.

Problem: Thought.run uses Task.async which creates a linked task. If the task
crashes, the Brain GenServer dies because try/catch doesn't catch exit signals
from linked processes.

Fix: Temporarily trap exits around activity execution, then restore.
"""

import sys

brain_path = sys.argv[1] if len(sys.argv) > 1 else "lib/kudzu/brain/brain.ex"

with open(brain_path, "r") as f:
    content = f.read()

# Replace the try block with trap_exit + try
old_try = """    # Run the most overdue activity (wrapped in try/catch for resilience)
    state =
      try do"""

new_try = """    # Run the most overdue activity (wrapped in trap_exit + try/catch for resilience)
    # Trap exits temporarily so linked Task.async crashes don't kill the Brain
    old_trap = Process.flag(:trap_exit, true)
    state =
      try do"""

# Replace the catch block to also restore trap_exit
old_catch = """      catch
        kind, reason ->
          Logger.warning("[Brain] Activity crashed: \#{inspect(kind)}: \#{inspect(reason)}")
          state  # Return unchanged state on crash
      end"""

new_catch = """      catch
        kind, reason ->
          Logger.warning("[Brain] Activity crashed: \#{inspect(kind)}: \#{inspect(reason)}")
          state  # Return unchanged state on crash
      after
        Process.flag(:trap_exit, old_trap)
        # Flush any trapped EXIT messages so they don't pile up
        receive do
          {:EXIT, _pid, _reason} -> :ok
        after
          0 -> :ok
        end
      end"""

if old_try in content and old_catch in content:
    content = content.replace(old_try, new_try)
    content = content.replace(old_catch, new_catch)
    with open(brain_path, "w") as f:
        f.write(content)
    print("Added trap_exit wrapper to activity loop")
else:
    if old_try not in content:
        print("ERROR: Could not find try block")
    if old_catch not in content:
        print("ERROR: Could not find catch block")
    sys.exit(1)
