# Justified Dialyzer suppressions. Each entry MUST carry a one-line "why"
# comment explaining the false-positive rationale and a signoff.
#
# Phase 5 type-discipline pass (2026-06-09): triaged 176 baseline warnings.
# The remaining suppressions fall into 3 categories:
#
#  1. Defensive error branches in HTTP/MCP controllers + handlers. The current
#     implementation specs return only {:ok, _} (Hologram.record_trace +
#     GenServer.call patterns can't fail without crashing), but the controllers
#     retain `{:error, _} -> ...` branches as defensive code that future-proofs
#     against API loosening. Removing them would couple the controllers to the
#     current narrow spec; keeping them with this suppression keeps the
#     defensive structure visible without dialyzer noise.
#
#  2. Macro-injected pattern matches in Kudzu.Beamlet.Base. The Base's
#     __using__ macro generates a `case handle_request/2 do` block that
#     dispatches on {:ok, _} | {:error, _} | {:async, _}, but concrete
#     beamlets like Kudzu.Beamlet.IO and Kudzu.Beamlet.Scheduler don't
#     implement the :async path. The :async clause is therefore unreachable
#     for those beamlets but is the structural contract Base expects from
#     beamlets that DO use async (currently none, but the architecture
#     supports it). Removing the :async clause from Base would shut the door
#     to that future.
#
#  3. `defmodule:1:pattern_match` warnings (Type: true, Pattern: false).
#     These are dialyzer's report when a try/rescue or boolean expression
#     somewhere in the module has a branch that is provably unreachable.
#     The :1 line number indicates dialyzer can't pinpoint the specific
#     site; these are usually defensive `with ... else _ -> false` patterns
#     that the analyzer proves always succeed.
[
  # Category 1: defensive {:error, _} branches in HTTP / MCP controllers.
  # Each call site routes through Kudzu.Agent.remember / learn / think /
  # observe / decide, all of which currently return only {:ok, trace_id()}.
  # If those specs ever loosen, removing the {:error, _} branch loses error
  # handling. Keep the branches; suppress dialyzer.
  {"lib/kudzu_web/controllers/agent_controller.ex", :pattern_match},
  {"lib/kudzu_web/controllers/hologram_controller.ex", :pattern_match},
  {"lib/kudzu_web/controllers/constitution_controller.ex", :pattern_match_cov},
  {"lib/kudzu_web/mcp/handlers/agent.ex", :pattern_match},
  {"lib/kudzu_web/mcp/handlers/hologram.ex", :pattern_match},
  {"lib/kudzu_web/channels/hologram_channel.ex", :pattern_match},

  # Category 2: macro-injected {:async, _} dispatch in Beamlet.Base.__using__.
  # Concrete beamlets (IO, Scheduler) don't use the async path; Base supports
  # it for future async-capable beamlets. The pattern is intentionally broad.
  {"lib/kudzu/beamlet/io.ex", :pattern_match},
  {"lib/kudzu/beamlet/scheduler.ex", :pattern_match},

  # Category 3: defmodule:1 pattern_match (Pattern: false, Type: true) —
  # dialyzer can't pinpoint the line; these are defensive boolean expressions
  # whose false branch is provably unreachable. Reviewed the modules; no
  # actionable site. Suppressing module-level only.
  {"lib/kudzu/agent.ex", :pattern_match, 1},
  {"lib/kudzu/brain/chat.ex", :pattern_match, 1},
  {"lib/kudzu/constitution.ex", :pattern_match, 1},
  {"lib/kudzu/storage.ex", :pattern_match, 1}
]
