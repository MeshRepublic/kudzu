defmodule Kudzu.SignalHandler do
  @moduledoc """
  Translates OS SIGTERM into a graceful BEAM shutdown via `System.stop/1`.

  ## Why this exists

  In `mix run --no-halt` mode the BEAM does not auto-translate SIGTERM into
  `:init.stop/0`. systemd's SIGTERM is ignored until its stop timeout elapses
  and SIGKILL fires, leaving DETS / Mnesia state dirty and skipping
  `terminate/2` callbacks throughout the supervision tree.

  This handler — attached to the OTP `:erl_signal_server` `gen_event` —
  catches SIGTERM and asks the application to stop cleanly. The supervision
  tree then cascades termination through its children, which gives each
  `GenServer` a chance to flush its persistent state before the VM exits.

  Installation happens in `Kudzu.Application.start/2` after the supervisor
  tree is up. See that module for the installation call.

  ## Why only SIGTERM

  `:os.set_signal/2` accepts only a fixed allowlist of signals. `:sigint` is
  not in it (the BEAM's break handler owns INT). `:sigquit` is claimed by
  Elixir's `System.SignalHandler` for the interactive test runner trace dump
  (Ctrl-\\). SIGTERM is the only one systemd uses, so handling just that is
  sufficient.
  """

  @behaviour :gen_event

  require Logger

  @impl :gen_event
  def init(_args), do: {:ok, %{}}

  @impl :gen_event
  def handle_event(:sigterm, state) do
    Logger.warning(
      "[Kudzu.SignalHandler] SIGTERM received — initiating graceful shutdown via System.stop/1"
    )

    # System.stop/1 is asynchronous: it returns immediately and schedules
    # :init.stop/0. We spawn a task to invoke it so the gen_event callback
    # returns promptly, freeing the signal-server loop to handle further
    # events (e.g. a second SIGTERM while shutdown is in progress).
    Task.start(fn -> System.stop(0) end)

    {:ok, state}
  end

  def handle_event(_other, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def handle_info(_msg, state), do: {:ok, state}
end
