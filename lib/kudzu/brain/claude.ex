defmodule Kudzu.Brain.Claude do
  @moduledoc """
  Claude API client for Tier 3 reasoning.

  Provides a pure-function request/response pipeline and a tool-use loop
  for multi-turn agentic reasoning. Uses raw `:httpc` (Erlang) — no extra
  dependencies beyond what OTP and Jason already provide.

  ## Usage

      # Single call
      {:ok, response} = Claude.call(api_key, messages, tools, opts)

      # Multi-turn reasoning with tool loop
      {:ok, text, usage} = Claude.reason(
        api_key,
        "You are a system health monitor.",
        "Check if all holograms are healthy.",
        tools,
        &execute_tool/2
      )
  """

  require Logger

  # ── Constants ───────────────────────────────────────────────────────

  @api_url ~c"https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 4096
  @timeout 120_000

  # ── Structs ─────────────────────────────────────────────────────────

  defmodule ToolCall do
    @moduledoc """
    Represents a single tool-use request from Claude.
    """
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            input: map()
          }
    defstruct [:id, :name, :input]
  end

  defmodule Response do
    @moduledoc """
    Parsed response from the Claude Messages API.
    """
    @type t :: %__MODULE__{
            text: String.t(),
            tool_calls: [Kudzu.Brain.Claude.ToolCall.t()],
            stop_reason: String.t(),
            usage: map()
          }
    defstruct text: "", tool_calls: [], stop_reason: nil, usage: %{}
  end

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Builds a request body map for the Claude Messages API.

  Normalizes messages (atom keys to string keys) and assembles the
  top-level fields. Only includes "system" and "tools" when provided.

  ## Options

    * `:model` — model ID (default `#{@default_model}`)
    * `:max_tokens` — max response tokens (default `#{@default_max_tokens}`)
    * `:system` — system prompt string
  """
  @spec build_request(list(map()), list(map()), keyword()) :: map()
  def build_request(messages, tools \\ [], opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    system = Keyword.get(opts, :system)

    body =
      %{
        "model" => model,
        "max_tokens" => max_tokens,
        "messages" => Enum.map(messages, &normalize_message/1)
      }

    body = if system, do: Map.put(body, "system", system), else: body
    body = if tools != [], do: Map.put(body, "tools", tools), else: body

    body
  end

  @doc """
  Parses a decoded JSON response map into a `Response` struct.

  Extracts text from all "text" content blocks (joined), maps "tool_use"
  blocks to `ToolCall` structs, and pulls out stop_reason and usage.
  """
  @spec parse_response(map()) :: Response.t()
  def parse_response(response_map) do
    content_blocks = Map.get(response_map, "content", [])

    text =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])

    tool_calls =
      content_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %ToolCall{
          id: block["id"],
          name: block["name"],
          input: block["input"]
        }
      end)

    usage_raw = Map.get(response_map, "usage", %{})

    usage = %{
      input_tokens: Map.get(usage_raw, "input_tokens", 0),
      output_tokens: Map.get(usage_raw, "output_tokens", 0)
    }

    %Response{
      text: text,
      tool_calls: tool_calls,
      stop_reason: Map.get(response_map, "stop_reason"),
      usage: usage
    }
  end

  @doc """
  Creates a tool_result message for continuing a tool-use conversation.

  If `result` is a binary string it is used as-is; otherwise it is
  JSON-encoded via `Jason.encode!/1`.
  """
  @spec build_tool_result(String.t(), term()) :: map()
  def build_tool_result(tool_use_id, result) do
    content =
      if is_binary(result) do
        result
      else
        Jason.encode!(result)
      end

    %{
      role: "user",
      content: [
        %{
          "type" => "tool_result",
          "tool_use_id" => tool_use_id,
          "content" => content
        }
      ]
    }
  end

  @doc """
  Makes a single HTTP POST to the Claude Messages API.

  Returns `{:ok, %Response{}}` on success, or `{:error, reason}` on
  failure. Headers and URL are charlists as required by `:httpc`;
  the request body is a binary.

  ## Options

  Passed through to `build_request/3` — see its docs for details.
  """
  @spec call(String.t(), list(map()), list(map()), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def call(api_key, messages, tools \\ [], opts \\ []) do
    body = build_request(messages, tools, opts)
    json_body = Jason.encode!(body)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", String.to_charlist(@api_version)}
    ]

    http_opts = [
      timeout: @timeout,
      connect_timeout: @timeout
    ]

    request = {@api_url, headers, ~c"application/json", json_body}

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_http_ver, 200, _reason}, _resp_headers, resp_body}} ->
        parsed = Jason.decode!(to_string(resp_body))
        {:ok, parse_response(parsed)}

      {:ok, {{_http_ver, status, _reason}, _resp_headers, resp_body}} ->
        body_str = to_string(resp_body)
        Logger.warning("[Claude] API error #{status}: #{String.slice(body_str, 0, 500)}")
        {:error, {:api_error, status, body_str}}

      {:error, reason} ->
        Logger.error("[Claude] HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Runs a multi-turn tool-use reasoning loop.

  Sends `initial_message` to Claude with the given `system_prompt` and
  `tools`. When Claude requests tool use, each call is executed via
  `tool_executor` (a `(name, input) -> result` function) and the results
  are fed back. The loop continues until Claude returns "end_turn" or
  the safety cap of `:max_turns` (default 10) is reached.

  Returns `{:ok, final_text, usage_summary}` on success.

  ## Options

    * `:max_turns` — safety cap on reasoning turns (default 10)
    * All other options are forwarded to `call/4`.
  """
  @spec reason(
          String.t(),
          String.t(),
          String.t(),
          list(map()),
          (String.t(), map() -> term()),
          keyword()
        ) :: {:ok, String.t(), map()} | {:error, term()}
  def reason(api_key, system_prompt, initial_message, tools, tool_executor, opts \\ []) do
    {max_turns, call_opts} = Keyword.pop(opts, :max_turns, 10)
    call_opts = Keyword.put(call_opts, :system, system_prompt)

    initial_messages = [%{role: "user", content: initial_message}]

    initial_usage = %{input_tokens: 0, output_tokens: 0, turns: 0}

    reason_loop(api_key, initial_messages, tools, tool_executor, call_opts, initial_usage, max_turns)
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp reason_loop(_api_key, _messages, _tools, _tool_executor, _opts, usage, max_turns)
       when usage.turns >= max_turns do
    {:error, {:max_turns_exceeded, usage}}
  end

  defp reason_loop(api_key, messages, tools, tool_executor, opts, usage, max_turns) do
    case call(api_key, messages, tools, opts) do
      {:ok, %Response{} = response} ->
        new_usage = accumulate_usage(usage, response.usage)

        case response.stop_reason do
          "end_turn" ->
            {:ok, response.text, new_usage}

          "tool_use" ->
            assistant_msg = %{
              role: "assistant",
              content: rebuild_content_blocks(response)
            }

            tool_result_msgs =
              Enum.map(response.tool_calls, fn %ToolCall{id: id, name: name, input: input} ->
                result = tool_executor.(name, input)
                build_tool_result(id, result)
              end)

            updated_messages = messages ++ [assistant_msg | tool_result_msgs]

            reason_loop(
              api_key,
              updated_messages,
              tools,
              tool_executor,
              opts,
              new_usage,
              max_turns
            )

          other ->
            # Unexpected stop reason — return what we have
            Logger.warning("[Claude] Unexpected stop_reason: #{inspect(other)}")
            {:ok, response.text, new_usage}
        end

      {:error, _} = error ->
        error
    end
  end

  defp accumulate_usage(acc, response_usage) do
    %{
      input_tokens: acc.input_tokens + Map.get(response_usage, :input_tokens, 0),
      output_tokens: acc.output_tokens + Map.get(response_usage, :output_tokens, 0),
      turns: acc.turns + 1
    }
  end

  # Rebuilds content blocks array from a Response for the assistant message,
  # preserving both text and tool_use blocks in conversation history.
  defp rebuild_content_blocks(%Response{text: text, tool_calls: tool_calls}) do
    text_blocks =
      if text != "" do
        [%{"type" => "text", "text" => text}]
      else
        []
      end

    tool_blocks =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name, input: input} ->
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      end)

    text_blocks ++ tool_blocks
  end

  defp normalize_message(msg) when is_map(msg) do
    role =
      case Map.get(msg, :role) || Map.get(msg, "role") do
        r when is_atom(r) -> Atom.to_string(r)
        r when is_binary(r) -> r
      end

    content = Map.get(msg, :content) || Map.get(msg, "content")

    %{"role" => role, "content" => content}
  end
end
