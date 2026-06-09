defmodule KudzuWeb.HologramControllerTest do
  use ExUnit.Case, async: true

  alias KudzuWeb.HologramController

  describe "sanitize_utf8/1" do
    test "passes through clean ASCII" do
      assert HologramController.sanitize_utf8("hello world") == "hello world"
    end

    test "passes through well-formed multi-byte UTF-8" do
      # "now let's" with a real curly apostrophe (U+2019, encoded 0xE2 0x80 0x99)
      ok = <<"now let", 0xE2, 0x80, 0x99, "s">>
      assert HologramController.sanitize_utf8(ok) == ok
    end

    test "replaces a truncated multi-byte sequence with U+FFFD" do
      # Same string truncated mid-codepoint — the trailing 0x99 byte is lost,
      # leaving 0xE2 0x80 dangling. This is the exact byte pattern from the
      # live web_knowledge silo trace that 500'd /api/v1/holograms/:id/traces.
      bad = <<"now let", 0xE2, 0x80>>
      result = HologramController.sanitize_utf8(bad)

      # Result must be encodable as JSON (the original requirement) and
      # must include the replacement character so the corruption is
      # surfaced visibly.
      assert {:ok, _} = Jason.encode(%{content: result})
      assert String.contains?(result, "�")
      assert String.starts_with?(result, "now let")
    end

    test "walks into maps and replaces bad UTF-8 in values" do
      bad = <<"x", 0xE2, 0x80>>
      hint = %{"type" => "page_summary", "content" => bad, "ok" => "fine"}

      sanitized = HologramController.sanitize_utf8(hint)
      assert {:ok, _} = Jason.encode(sanitized)
      assert sanitized["ok"] == "fine"
      assert String.contains?(sanitized["content"], "�")
    end

    test "walks into nested structures (map -> list -> binary)" do
      bad = <<"x", 0xE2, 0x80>>
      payload = %{"items" => [%{"text" => bad}, %{"text" => "clean"}]}

      sanitized = HologramController.sanitize_utf8(payload)
      assert {:ok, _} = Jason.encode(sanitized)

      [first, second] = sanitized["items"]
      assert String.contains?(first["text"], "�")
      assert second["text"] == "clean"
    end

    test "leaves non-string values untouched" do
      assert HologramController.sanitize_utf8(42) == 42
      assert HologramController.sanitize_utf8(:atom) == :atom
      assert HologramController.sanitize_utf8(true) == true
      assert HologramController.sanitize_utf8(nil) == nil
    end
  end
end
