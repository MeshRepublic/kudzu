defmodule KudzuWeb.MCP.SessionTest do
  use ExUnit.Case, async: false
  alias KudzuWeb.MCP.Session

  setup do
    start_supervised!(Session)
    :ok
  end

  test "create returns a session ID" do
    {:ok, session_id} = Session.create()
    assert is_binary(session_id)
    assert String.length(session_id) > 0
  end

  test "validate returns true for valid session" do
    {:ok, session_id} = Session.create()
    assert Session.valid?(session_id) == true
  end

  test "validate returns false for unknown session" do
    assert Session.valid?("nonexistent") == false
  end

  test "touch updates last_active" do
    {:ok, session_id} = Session.create()
    :ok = Session.touch(session_id)
    assert Session.valid?(session_id) == true
  end

  test "destroy removes session" do
    {:ok, session_id} = Session.create()
    :ok = Session.destroy(session_id)
    assert Session.valid?(session_id) == false
  end
end
