#!/usr/bin/env python3
"""Replace wake_cycle handlers with activity_cycle handlers (line-based)."""

import sys

brain_path = sys.argv[1] if len(sys.argv) > 1 else "lib/kudzu/brain/brain.ex"

with open(brain_path, "r") as f:
    lines = f.readlines()

# Find the nil wake_cycle handler start (line 285 in current file, 0-indexed = 284)
nil_start = None
main_start = None
main_end = None

for i, line in enumerate(lines):
    if "def handle_info(:wake_cycle, %{hologram_id: nil}" in line:
        nil_start = i
    elif "def handle_info(:wake_cycle, state) do" in line:
        main_start = i
    elif main_start is not None and main_end is None and line.strip() == "end":
        # Count nesting to find the right end
        # We need the top-level end after main_start
        # Check if we're back to 2-space indent end
        if line == "  end\n" or line == "  end":
            main_end = i

if nil_start is None or main_start is None or main_end is None:
    print(f"ERROR: Could not find handlers. nil_start={nil_start}, main_start={main_start}, main_end={main_end}")
    sys.exit(1)

print(f"Found nil handler at line {nil_start + 1}")
print(f"Found main handler at lines {main_start + 1}-{main_end + 1}")

new_handlers = """\
  # Backward compatibility: :wake_cycle forwards to :activity_cycle
  def handle_info(:wake_cycle, state) do
    send(self(), :activity_cycle)
    {:noreply, state}
  end

  def handle_info(:activity_cycle, %{hologram_id: nil} = state) do
    Logger.debug("[Brain] Skipping activity cycle \u2014 no hologram attached")
    schedule_activity_cycle()
    {:noreply, state}
  end

  def handle_info(:activity_cycle, state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | status: :active}

    # Run the most overdue activity
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
      end

    # Decay working memory periodically
    state = if state.working_memory do
      %{state | working_memory: WorkingMemory.decay(state.working_memory, 0.01)}
    else
      state
    end

    schedule_activity_cycle()
    {:noreply, state}
  end
"""

# Replace lines from nil_start through main_end (inclusive)
new_lines = lines[:nil_start] + [new_handlers] + lines[main_end + 1:]

with open(brain_path, "w") as f:
    f.writelines(new_lines)

print(f"Replaced lines {nil_start + 1}-{main_end + 1} with activity_cycle handlers")
