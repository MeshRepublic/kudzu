defmodule Kudzu.Brain.Tools.Web do
  @moduledoc """
  Tier 2 web tools: search the internet and read web pages.

  Provides two tools for web access:

    * `web_search` — search the web via SearXNG (localhost:8888) with
      DuckDuckGo HTML fallback
    * `web_read`   — fetch a URL and extract readable text content

  Uses Erlang's built-in :httpc — no extra dependencies needed.
  """

  alias Kudzu.Brain.Tool

  require Logger

  @user_agent ~c"Kudzu/1.0 (Mesh Republic Knowledge Agent)"
  @http_timeout 10_000
  @max_content_bytes 100_000
  @searxng_url ~c"http://localhost:8888/search"

  # ── WebSearch ─────────────────────────────────────────────────────

  defmodule WebSearch do
    @moduledoc "Search the web for information."
    @behaviour Tool

    @impl true
    def name, do: "web_search"

    @impl true
    def description do
      "Search the web for information. Returns a list of results with titles, URLs, and snippets."
    end

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The search query"
          }
        },
        required: ["query"]
      }
    end

    @impl true
    def execute(params) do
      Kudzu.Brain.Tools.Web.execute("web_search", params)
    end
  end

  # ── WebRead ───────────────────────────────────────────────────────

  defmodule WebRead do
    @moduledoc "Fetch and read a web page."
    @behaviour Tool

    @impl true
    def name, do: "web_read"

    @impl true
    def description do
      "Fetch a URL and extract its text content. Returns the page text, word count, and title."
    end

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "The URL to fetch (must be http:// or https://)"
          }
        },
        required: ["url"]
      }
    end

    @impl true
    def execute(params) do
      Kudzu.Brain.Tools.Web.execute("web_read", params)
    end
  end

  # ── Module-Level Functions ────────────────────────────────────────

  @doc "Returns the list of all web tool modules."
  @spec all_tools() :: [module()]
  def all_tools, do: [WebSearch, WebRead]

  @doc "Converts all web tools to Claude API format."
  @spec to_claude_format() :: [map()]
  def to_claude_format do
    Enum.map(all_tools(), &Tool.to_claude_format/1)
  end

  @doc """
  Dispatch a tool call by name string.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec execute(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute("web_search", %{"query" => query}) when byte_size(query) == 0 do
    {:error, "query must not be empty"}
  end

  def execute("web_search", %{"query" => query}) do
    ensure_httpc_started()

    case search_searxng(query) do
      {:ok, results} ->
        {:ok, %{source: "searxng", query: query, results: results, count: length(results)}}

      {:error, _reason} ->
        Logger.info("[Web] SearXNG unavailable, falling back to DuckDuckGo")

        case search_duckduckgo(query) do
          {:ok, results} ->
            {:ok, %{source: "duckduckgo", query: query, results: results, count: length(results)}}

          {:error, reason} ->
            {:error, "web search failed: #{reason}"}
        end
    end
  rescue
    e -> {:error, "web_search crashed: #{Exception.message(e)}"}
  end

  def execute("web_read", %{"url" => url}) do
    cond do
      not (String.starts_with?(url, "http://") or String.starts_with?(url, "https://")) ->
        {:error, "URL must start with http:// or https://"}

      true ->
        ensure_httpc_started()

        case fetch_url(url) do
          {:ok, body} ->
            title = extract_title(body)
            text = strip_html(body)
            word_count = text |> String.split(~r/\s+/, trim: true) |> length()

            {:ok, %{url: url, title: title, text: text, word_count: word_count}}

          {:error, reason} ->
            {:error, "web_read failed: #{reason}"}
        end
    end
  rescue
    e -> {:error, "web_read crashed: #{Exception.message(e)}"}
  end

  def execute(name, _params) do
    {:error, "unknown web tool: #{name}"}
  end

  @doc """
  Extract knowledge triples from text using pattern-based extraction.

  Delegates to `Kudzu.Silo.Extractor.extract_patterns/1`.
  """
  @spec extract_knowledge(String.t()) :: list({String.t(), String.t(), String.t()})
  def extract_knowledge(text) when is_binary(text) do
    Kudzu.Silo.Extractor.extract_patterns(text)
  end

  # ── SearXNG Search ────────────────────────────────────────────────

  defp search_searxng(query) do
    encoded_query = URI.encode_www_form(query)
    url = @searxng_url ++ String.to_charlist("?q=#{encoded_query}&format=json")

    case :httpc.request(
           :get,
           {url, [{~c"User-Agent", @user_agent}]},
           [timeout: @http_timeout, connect_timeout: 5000],
           [body_format: :binary]
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results}} ->
            parsed =
              results
              |> Enum.take(10)
              |> Enum.map(fn r ->
                %{
                  title: Map.get(r, "title", ""),
                  url: Map.get(r, "url", ""),
                  snippet: Map.get(r, "content", "")
                }
              end)

            {:ok, parsed}

          _ ->
            {:error, "failed to parse SearXNG response"}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "SearXNG returned status #{status}"}

      {:error, reason} ->
        {:error, "SearXNG request failed: #{inspect(reason)}"}
    end
  end

  # ── DuckDuckGo Fallback ───────────────────────────────────────────

  defp search_duckduckgo(query) do
    encoded_query = URI.encode_www_form(query)
    url = String.to_charlist("https://html.duckduckgo.com/html/?q=#{encoded_query}")

    ssl_opts = ssl_options()

    case :httpc.request(
           :get,
           {url, [{~c"User-Agent", @user_agent}]},
           [timeout: @http_timeout, connect_timeout: 5000] ++ ssl_opts,
           [body_format: :binary]
         ) do
      {:ok, {{_, status, _}, _headers, body}} when status in [200, 301, 302] ->
        results = parse_duckduckgo_html(body)
        {:ok, results}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "DuckDuckGo returned status #{status}"}

      {:error, reason} ->
        {:error, "DuckDuckGo request failed: #{inspect(reason)}"}
    end
  end

  defp parse_duckduckgo_html(html) do
    # DuckDuckGo HTML results are in <div class="result ..."> blocks
    # Each has an <a class="result__a"> for the title/URL
    # and a <a class="result__snippet"> for the snippet

    # Try to extract result blocks via the result__a links
    links = Regex.scan(~r/<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/s, html)

    snippets = Regex.scan(~r/<a[^>]*class="result__snippet"[^>]*>(.*?)<\/a>/s, html)

    if length(links) > 0 do
      links
      |> Enum.take(10)
      |> Enum.with_index()
      |> Enum.map(fn {[_full, raw_url, raw_title], idx} ->
        snippet =
          case Enum.at(snippets, idx) do
            [_, s] -> strip_html(s) |> String.trim()
            _ -> ""
          end

        %{
          title: strip_html(raw_title) |> String.trim(),
          url: clean_ddg_url(raw_url),
          snippet: snippet
        }
      end)
    else
      # Fallback: try generic link extraction from result divs
      Regex.scan(~r/<a[^>]+class="[^"]*result[^"]*"[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/s, html)
      |> Enum.take(10)
      |> Enum.map(fn [_full, raw_url, raw_title] ->
        %{
          title: strip_html(raw_title) |> String.trim(),
          url: clean_ddg_url(raw_url),
          snippet: ""
        }
      end)
    end
  end

  defp clean_ddg_url(url) do
    # DuckDuckGo wraps URLs in redirect links like //duckduckgo.com/l/?uddg=...
    parsed = URI.parse(url)
    query_params = URI.decode_query(parsed.query || "")

    case Map.get(query_params, "uddg") do
      nil -> url
      real_url -> real_url
    end
  rescue
    _ -> url
  end

  # ── URL Fetching ──────────────────────────────────────────────────

  defp fetch_url(url) do
    fetch_url(url, 0)
  end

  defp fetch_url(_url, redirects) when redirects > 5 do
    {:error, "too many redirects"}
  end

  defp fetch_url(url, redirects) do
    charlist_url = String.to_charlist(url)

    ssl_opts =
      if String.starts_with?(url, "https://") do
        ssl_options()
      else
        []
      end

    case :httpc.request(
           :get,
           {charlist_url, [{~c"User-Agent", @user_agent}]},
           [timeout: @http_timeout, connect_timeout: 5000] ++ ssl_opts,
           [body_format: :binary]
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        truncated =
          if byte_size(body) > @max_content_bytes do
            binary_part(body, 0, @max_content_bytes)
          else
            body
          end

        {:ok, truncated}

      {:ok, {{_, status, _}, headers, _body}} when status in [301, 302, 303, 307, 308] ->
        location =
          headers
          |> Enum.find_value(fn
            {key, val} ->
              key_str =
                case key do
                  k when is_list(k) -> List.to_string(k)
                  k when is_binary(k) -> k
                end

              if String.downcase(key_str) == "location" do
                case val do
                  v when is_list(v) -> List.to_string(v)
                  v when is_binary(v) -> v
                end
              end
          end)

        if location do
          # Handle relative redirects
          absolute_url =
            if String.starts_with?(location, "http") do
              location
            else
              uri = URI.parse(url)
              "#{uri.scheme}://#{uri.host}#{location}"
            end

          fetch_url(absolute_url, redirects + 1)
        else
          {:error, "redirect with no location header (status #{status})"}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # ── HTML Processing ───────────────────────────────────────────────

  defp extract_title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/si, html) do
      [_, title] ->
        title
        |> String.trim()
        |> decode_html_entities()

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  @doc false
  def strip_html(html) when is_binary(html) do
    html
    # Remove script and style blocks
    |> String.replace(~r/<script[^>]*>.*?<\/script>/si, " ")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/si, " ")
    |> String.replace(~r/<nav[^>]*>.*?<\/nav>/si, " ")
    |> String.replace(~r/<header[^>]*>.*?<\/header>/si, " ")
    |> String.replace(~r/<footer[^>]*>.*?<\/footer>/si, " ")
    # Remove HTML comments
    |> String.replace(~r/<!--.*?-->/s, " ")
    # Replace block elements with newlines
    |> String.replace(~r/<(br|hr|\/p|\/div|\/h[1-6]|\/li|\/tr)[^>]*>/i, "\n")
    # Remove all remaining tags
    |> String.replace(~r/<[^>]*>/, " ")
    # Decode common HTML entities
    |> decode_html_entities()
    # Normalize whitespace
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s*\n+/, "\n\n")
    |> String.trim()
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&mdash;", "-")
    |> String.replace("&ndash;", "-")
    |> String.replace("&hellip;", "...")
  end

  # ── SSL Helpers ───────────────────────────────────────────────────

  defp ssl_options do
    [
      ssl: [
        verify: :verify_none,
        depth: 3
      ]
    ]
  end

  defp ensure_httpc_started do
    :inets.start()
    :ssl.start()
  end
end
