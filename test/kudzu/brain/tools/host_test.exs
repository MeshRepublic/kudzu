defmodule Kudzu.Brain.Tools.HostTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Tools.Host

  describe "CheckDisk" do
    test "returns partition info" do
      {:ok, result} = Host.CheckDisk.execute(%{})
      assert is_list(result.partitions)
      assert length(result.partitions) > 0

      partition = hd(result.partitions)
      assert partition.mount != nil
      assert partition.used_percent != nil
    end
  end

  describe "CheckMemory" do
    test "returns memory stats" do
      {:ok, result} = Host.CheckMemory.execute(%{})
      assert result.total_mb != nil
      assert result.used_mb != nil
      assert result.free_mb != nil
      assert result.available_mb != nil
    end
  end

  describe "CheckProcess" do
    test "finds beam process" do
      {:ok, result} = Host.CheckProcess.execute(%{"name" => "beam"})
      assert result.running == true
      assert result.count > 0
      assert is_list(result.processes)
    end

    test "handles missing process" do
      {:ok, result} = Host.CheckProcess.execute(%{"name" => "nonexistent_xyzzy_12345"})
      assert result.running == false
      assert result.count == 0
      assert result.processes == []
    end
  end

  describe "module-level functions" do
    test "all_tools returns 3 tool modules" do
      assert length(Host.all_tools()) == 3
    end

    test "to_claude_format returns valid tool definitions" do
      formats = Host.to_claude_format()
      assert length(formats) == 3

      names = Enum.map(formats, & &1.name)
      assert "check_disk" in names
      assert "check_memory" in names
      assert "check_process" in names

      Enum.each(formats, fn fmt ->
        assert is_binary(fmt.name)
        assert is_binary(fmt.description)
        assert is_map(fmt.input_schema)
      end)
    end

    test "execute dispatches to correct tool" do
      {:ok, result} = Host.execute("check_memory", %{})
      assert result.total_mb != nil
    end

    test "execute returns error for unknown tool" do
      assert {:error, _msg} = Host.execute("nonexistent", %{})
    end
  end
end
