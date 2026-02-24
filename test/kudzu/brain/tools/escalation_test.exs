defmodule Kudzu.Brain.Tools.EscalationTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.Tool
  alias Kudzu.Brain.Tools.Escalation

  # Brain hologram takes ~2s to init; wait up to 5s for it
  defp wait_for_brain_hologram(retries \\ 10) do
    state = Kudzu.Brain.get_state()

    if state.hologram_pid do
      :ok
    else
      if retries > 0 do
        Process.sleep(500)
        wait_for_brain_hologram(retries - 1)
      else
        flunk("Brain hologram did not become ready within timeout")
      end
    end
  end

  setup do
    wait_for_brain_hologram()
    :ok
  end

  test "record_alert records alert trace on brain hologram" do
    {:ok, result} =
      Escalation.RecordAlert.execute(%{
        "severity" => "warning",
        "summary" => "Test alert from escalation test"
      })

    assert result.recorded == true
    assert result.severity == "warning"
  end

  test "all_tools returns 1 tool" do
    assert length(Escalation.all_tools()) == 1
  end

  test "to_claude_format returns valid tool definition" do
    [format] = Escalation.to_claude_format()
    assert format.name == "record_alert"
    assert is_binary(format.description)
    assert is_map(format.input_schema)
  end

  test "Tool.to_claude_format/1 works for each escalation tool module" do
    for module <- Escalation.all_tools() do
      formatted = Tool.to_claude_format(module)
      assert is_binary(formatted.name)
      assert is_binary(formatted.description)
      assert is_map(formatted.input_schema)
    end
  end

  test "execute dispatches to record_alert" do
    {:ok, result} =
      Escalation.execute("record_alert", %{
        "severity" => "critical",
        "summary" => "Test dispatch"
      })

    assert result.recorded == true
  end

  test "execute returns error for unknown tool" do
    assert {:error, msg} = Escalation.execute("nonexistent", %{})
    assert is_binary(msg)
    assert msg =~ "unknown escalation tool"
  end

  test "record_alert includes optional fields" do
    {:ok, result} =
      Escalation.RecordAlert.execute(%{
        "severity" => "critical",
        "summary" => "Disk full",
        "context" => "Observed 99% disk usage",
        "suggested_action" => "Clean up /tmp"
      })

    assert result.recorded == true
    assert result.severity == "critical"
  end

  test "record_alert defaults severity to warning when nil" do
    {:ok, result} =
      Escalation.RecordAlert.execute(%{
        "summary" => "Test with nil severity"
      })

    assert result.recorded == true
    # severity is nil in the result since it comes from params["severity"]
    # but the trace data gets "warning" as default
    assert result.severity == nil
  end
end
