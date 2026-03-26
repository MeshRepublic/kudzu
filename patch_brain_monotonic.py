#!/usr/bin/env python3
"""Fix monotonic time initialization bug in brain.ex.

Problem: last_* fields default to 0, but System.monotonic_time(:millisecond)
returns large negative numbers (~-576 trillion). So (now - 0) is always negative
and overdue? never fires.

Fix: Initialize to nil, and treat nil as "never ran = always overdue".
"""

import sys

brain_path = sys.argv[1] if len(sys.argv) > 1 else "lib/kudzu/brain/brain.ex"

with open(brain_path, "r") as f:
    content = f.read()

# 1. Fix struct defaults: 0 -> nil
content = content.replace(
    "last_health_check: 0,",
    "last_health_check: nil,"
)
content = content.replace(
    "last_curiosity: 0,",
    "last_curiosity: nil,"
)
content = content.replace(
    "last_web_learning: 0,",
    "last_web_learning: nil,"
)
content = content.replace(
    "last_distillation: 0,",
    "last_distillation: nil,"
)
content = content.replace(
    "last_storage_check: 0,",
    "last_storage_check: nil,"
)

# 2. Fix overdue? to handle nil (never ran = always overdue)
content = content.replace(
    """  defp overdue?(last, interval, now) do
    (now - last) >= interval
  end""",
    """  defp overdue?(nil, _interval, _now), do: true
  defp overdue?(last, interval, now) do
    (now - last) >= interval
  end"""
)

with open(brain_path, "w") as f:
    f.write(content)

print("Fixed monotonic time initialization bug")
