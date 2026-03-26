#!/usr/bin/env python3
"""Wrap activity_cycle cond block in try/catch for resilience."""

import sys

brain_path = sys.argv[1] if len(sys.argv) > 1 else "lib/kudzu/brain/brain.ex"

with open(brain_path, "r") as f:
    content = f.read()

# Replace the bare cond block with a try/catch wrapped version
old_cond = """    # Run the most overdue activity
    state =
      cond do
        overdue?(state.last_health_check, @health_interval, now) ->
          Logger.debug("[Brain] Activity: health check")
          run_health_check(%{state | last_health_check: now})

        overdue?(state.last_distillation, @distillation_interval, now) ->
          Logger.debug("[Brain] Activity: distillation")
          run_distillation_cycle(%{state | last_distillation: now})

        overdue?(state.last_storage_check, @storage_interval, now) ->
          Logger.debug("[Brain] Activity: storage check")
          run_storage_check(%{state | last_storage_check: now})

        overdue?(state.last_web_learning, @web_learning_interval, now) ->
          Logger.debug("[Brain] Activity: web learning")
          run_web_learning(%{state | last_web_learning: now})

        overdue?(state.last_curiosity, @curiosity_interval, now) ->
          Logger.debug("[Brain] Activity: curiosity")
          run_curiosity(%{state | last_curiosity: now})

        true ->
          state  # Nothing overdue \u2014 idle tick
      end"""

new_cond = """    # Run the most overdue activity (wrapped in try/catch for resilience)
    state =
      try do
        cond do
          overdue?(state.last_health_check, @health_interval, now) ->
            Logger.debug("[Brain] Activity: health check")
            run_health_check(%{state | last_health_check: now})

          overdue?(state.last_distillation, @distillation_interval, now) ->
            Logger.debug("[Brain] Activity: distillation")
            run_distillation_cycle(%{state | last_distillation: now})

          overdue?(state.last_storage_check, @storage_interval, now) ->
            Logger.debug("[Brain] Activity: storage check")
            run_storage_check(%{state | last_storage_check: now})

          overdue?(state.last_web_learning, @web_learning_interval, now) ->
            Logger.debug("[Brain] Activity: web learning")
            run_web_learning(%{state | last_web_learning: now})

          overdue?(state.last_curiosity, @curiosity_interval, now) ->
            Logger.debug("[Brain] Activity: curiosity")
            run_curiosity(%{state | last_curiosity: now})

          true ->
            state  # Nothing overdue \u2014 idle tick
        end
      catch
        kind, reason ->
          Logger.warning("[Brain] Activity crashed: \#{inspect(kind)}: \#{inspect(reason)}")
          state  # Return unchanged state on crash
      end"""

if old_cond in content:
    content = content.replace(old_cond, new_cond)
    with open(brain_path, "w") as f:
        f.write(content)
    print("Activity loop wrapped in try/catch")
else:
    print("ERROR: Could not find cond block to wrap")
    sys.exit(1)
