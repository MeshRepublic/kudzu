defmodule Kudzu.SignalHandlerTest do
  @moduledoc """
  Tests safe branches of `Kudzu.SignalHandler`. The shutdown branch
  (`handle_event(:sigterm, ...)`) is not directly exercised here because it
  calls `System.stop/1`, which would terminate the test runner. It is
  validated by integration — restarting the kudzu systemd unit completes
  within the configured TimeoutStopSec.
  """

  use ExUnit.Case, async: false

  alias Kudzu.SignalHandler

  describe "installation" do
    test "handler is attached to :erl_signal_server after Application.start" do
      handlers = :gen_event.which_handlers(:erl_signal_server)

      assert SignalHandler in handlers,
             "Kudzu.SignalHandler not installed on :erl_signal_server; got #{inspect(handlers)}"
    end
  end

  describe "init/1" do
    test "returns an empty-state ok tuple" do
      assert {:ok, %{}} = SignalHandler.init([])
    end
  end

  describe "handle_event/2 — ignored signals" do
    test "non-SIGTERM signals are no-ops returning current state" do
      assert {:ok, %{}} = SignalHandler.handle_event(:sighup, %{})
      assert {:ok, %{}} = SignalHandler.handle_event(:sigchld, %{})
      assert {:ok, %{}} = SignalHandler.handle_event(:sigusr1, %{})
      assert {:ok, %{custom: :state}} = SignalHandler.handle_event(:sigwinch, %{custom: :state})
    end
  end

  describe "gen_event callbacks" do
    test "handle_call/2 returns :ok reply" do
      assert {:ok, :ok, %{}} = SignalHandler.handle_call(:anything, %{})
    end

    test "handle_info/2 ignores arbitrary messages" do
      assert {:ok, %{}} = SignalHandler.handle_info({:noise, :ignored}, %{})
    end
  end
end
