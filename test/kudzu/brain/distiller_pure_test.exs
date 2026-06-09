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

  describe "normalize_term/1 preserves technical punctuation (DP.2)" do
    test "preserves version dots (2.8.3 stays 2.8.3, not 283)" do
      assert "2.8.3" == Distiller.normalize_term("2.8.3")
    end

    test "preserves @ and dot in systemd instance names" do
      assert "user@1000.service" == Distiller.normalize_term("user@1000.service")
    end

    test "preserves dots and colon in host:port" do
      assert "0.0.0.0:8080" == Distiller.normalize_term("0.0.0.0:8080")
    end

    test "preserves leading slash and inner slashes in paths" do
      assert "/etc/systemd/system" == Distiller.normalize_term("/etc/systemd/system")
    end

    test "preserves hyphens in package names" do
      assert "apt-get" == Distiller.normalize_term("apt-get")
      assert "x86_64-linux-gnu" == Distiller.normalize_term("x86_64-linux-gnu")
    end

    test "collapses whitespace to underscore" do
      assert "hello_world" == Distiller.normalize_term("hello world")
      assert "multiple_spaces_here" == Distiller.normalize_term("multiple   spaces   here")
    end

    test "lowercases" do
      assert "abc" == Distiller.normalize_term("ABC")
      assert "user@1000.service" == Distiller.normalize_term("User@1000.Service")
    end

    test "strips leading and trailing whitespace" do
      assert "foo" == Distiller.normalize_term("   foo   ")
    end

    test "strips trailing sentence punctuation" do
      assert "foo" == Distiller.normalize_term("foo.")
      assert "foo" == Distiller.normalize_term("foo,")
      assert "foo" == Distiller.normalize_term("foo;")
      assert "foo" == Distiller.normalize_term("foo!")
      assert "foo" == Distiller.normalize_term("foo?")
    end

    test "strips disallowed characters (quotes, parens, brackets)" do
      assert "foo" == Distiller.normalize_term("\"foo\"")
      assert "foobar" == Distiller.normalize_term("(foo)bar")
      assert "foobar" == Distiller.normalize_term("[foo]bar")
    end

    test "handles empty and whitespace-only input" do
      assert "" == Distiller.normalize_term("")
      assert "" == Distiller.normalize_term("   ")
    end

    test "handles invalid UTF-8 gracefully" do
      # invalid UTF-8 byte sequence is truncated at the bad byte
      bad = <<"valid", 0xFF, "tail"::binary>>
      result = Distiller.normalize_term(bad)
      assert is_binary(result)
      assert String.starts_with?(result, "valid")
    end
  end
end
