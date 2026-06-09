defmodule Kudzu.Brain.DistillerPureTest do
  @moduledoc """
  Tests for the pure-function portion of `Kudzu.Brain.Distiller` — the parts
  that do NOT call Ollama or Claude. Kept in a separate module from
  `Kudzu.Brain.DistillerTest` so they run by default; the latter module is
  `:external`-tagged because its tests hit the Ollama HTTP API.
  """

  use ExUnit.Case, async: true

  alias Kudzu.Brain.Distiller

  describe "normalize_claude_triple/1 — no relation whitelist (DP.1)" do
    test "preserves runs_on (not in old whitelist) instead of coercing to relates_to" do
      assert {"kudzu", "runs_on", "titan"} =
               Distiller.normalize_claude_triple({"kudzu", "runs_on", "titan"})
    end

    test "preserves controls, shows, specifies (top systemctl relations)" do
      assert {"systemctl", "controls", "systemd"} =
               Distiller.normalize_claude_triple({"systemctl", "controls", "systemd"})

      assert {"ls", "shows", "files"} =
               Distiller.normalize_claude_triple({"ls", "shows", "files"})

      assert {"unit_file", "specifies", "service_type"} =
               Distiller.normalize_claude_triple({"unit_file", "specifies", "service_type"})
    end

    test "normalizes whitespace in relation to underscore" do
      assert {"a_word", "depends_on", "b_word"} =
               Distiller.normalize_claude_triple({"a_word", " depends on ", "b_word"})
    end

    test "lowercases relation" do
      assert {"foo", "causes", "bar"} =
               Distiller.normalize_claude_triple({"foo", "Causes", "bar"})
    end

    test "drops triple with empty subject or object" do
      assert nil == Distiller.normalize_claude_triple({"", "runs_on", "titan"})
      assert nil == Distiller.normalize_claude_triple({"kudzu", "runs_on", ""})
      # 1-char terms are dropped (length > 1 required by Distiller contract)
      assert nil == Distiller.normalize_claude_triple({"a", "runs_on", "b"})
    end

    test "drops triple with empty relation" do
      assert nil == Distiller.normalize_claude_triple({"kudzu", "   ", "titan"})
    end

    test "normalize_relation/1 collapses internal whitespace to underscore" do
      assert "runs_on" == Distiller.normalize_relation("runs on")
      assert "is_a_kind_of" == Distiller.normalize_relation("  is a kind of  ")
      assert "causes" == Distiller.normalize_relation("CAUSES")
    end
  end
end
