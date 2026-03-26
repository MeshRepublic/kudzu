# Test the Brain activity loop by running interactively
IO.puts("Kudzu started, waiting for Brain init...")
Process.sleep(5000)

state = Kudzu.Brain.get_state()
IO.puts("Brain status: #{state.status}")
IO.puts("Cycle count: #{state.cycle_count}")
IO.puts("Hologram: #{state.hologram_id}")

IO.puts("\nWatching for 120 seconds...")

for i <- 1..12 do
  Process.sleep(10_000)
  try do
    state = Kudzu.Brain.get_state()
    IO.puts("  t=#{i * 10}s | status=#{state.status} cycles=#{state.cycle_count}")
  catch
    kind, reason ->
      IO.puts("  t=#{i * 10}s | ERROR: #{inspect(kind)}: #{inspect(reason)}")
  end
end

IO.puts("\nDone watching. Brain survived!")
