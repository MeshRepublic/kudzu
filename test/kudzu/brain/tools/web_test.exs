defmodule Kudzu.Brain.Tools.WebTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.Tools.Web

  @moduletag :capture_log

  describe "web_search" do
    @tag :integration
    test "returns results for a query" do
      {:ok, results} = Web.execute("web_search", %{"query" => "Elixir programming language"})
      assert is_list(results.results)
      assert results.query == "Elixir programming language"
      assert results.source in ["searxng", "duckduckgo"]
    end

    test "returns error for empty query" do
      {:error, reason} = Web.execute("web_search", %{"query" => ""})
      assert is_binary(reason)
    end
  end

  describe "web_read" do
    @tag :integration
    test "fetches and extracts text from a URL" do
      {:ok, result} = Web.execute("web_read", %{"url" => "https://elixir-lang.org"})
      assert is_binary(result.text)
      assert result.word_count > 0
      assert is_binary(result.title)
      assert result.url == "https://elixir-lang.org"
    end

    test "rejects non-http URLs" do
      {:error, reason} = Web.execute("web_read", %{"url" => "file:///etc/passwd"})
      assert reason =~ "http"
    end

    test "rejects ftp URLs" do
      {:error, reason} = Web.execute("web_read", %{"url" => "ftp://example.com/file"})
      assert reason =~ "http"
    end
  end

  describe "extract_knowledge/1" do
    test "extracts relationship triples from text" do
      text = "Elixir is a functional programming language. Elixir uses the BEAM virtual machine."
      triples = Web.extract_knowledge(text)
      assert is_list(triples)
      assert length(triples) >= 1

      # Each triple should be {subject, relation, object}
      Enum.each(triples, fn {s, r, o} ->
        assert is_binary(s)
        assert is_binary(r)
        assert is_binary(o)
      end)
    end

    test "returns empty list for text with no extractable patterns" do
      triples = Web.extract_knowledge("Hello world")
      assert is_list(triples)
    end
  end

  describe "all_tools/0" do
    test "returns tool definitions" do
      tools = Web.all_tools()
      assert length(tools) == 2
      assert Web.WebSearch in tools
      assert Web.WebRead in tools
    end
  end

  describe "to_claude_format/0" do
    test "returns valid Claude API tool format" do
      formats = Web.to_claude_format()
      assert length(formats) == 2

      names = Enum.map(formats, & &1.name)
      assert "web_search" in names
      assert "web_read" in names

      Enum.each(formats, fn fmt ->
        assert is_binary(fmt.name)
        assert is_binary(fmt.description)
        assert is_map(fmt.input_schema)
      end)
    end
  end

  describe "execute/2 dispatch" do
    test "returns error for unknown tool" do
      assert {:error, _msg} = Web.execute("nonexistent", %{})
    end
  end

  describe "strip_html/1" do
    test "removes HTML tags" do
      assert Web.strip_html("<p>Hello <b>world</b></p>") =~ "Hello"
      assert Web.strip_html("<p>Hello <b>world</b></p>") =~ "world"
    end

    test "removes script and style blocks" do
      html = "<p>Before</p><script>alert('x')</script><p>After</p>"
      text = Web.strip_html(html)
      assert text =~ "Before"
      assert text =~ "After"
      refute text =~ "alert"
    end

    test "decodes HTML entities" do
      assert Web.strip_html("&amp; &lt; &gt;") == "& < >"
    end
  end
end
