defmodule Kudzu.Cognition do
  @moduledoc """
  Cognition layer for holograms using Ollama LLM.

  Transforms hologram state + stimulus into thoughts and actions.
  The hologram's traces and peer awareness become context for reasoning.
  """

  alias Kudzu.{Trace, VectorClock}
  alias Kudzu.Cognition.PromptBuilder

  @ollama_url "http://localhost:11434"
  @default_model "mistral:latest"
  @timeout 120_000

  @type action ::
          {:record_trace, purpose :: atom(), hints :: map()}
          | {:query_peer, peer_id :: String.t(), purpose :: atom()}
          | {:share_trace, peer_id :: String.t(), trace_id :: String.t()}
          | {:update_desire, desire :: String.t()}
          | {:respond, message :: String.t()}
          | :noop

  @type think_result :: {response :: String.t(), actions :: [action()], new_traces :: [map()]}

  @doc """
  Main cognition function. Takes hologram state and stimulus, returns response and actions.

  ## Parameters
    - state: hologram's current state (id, traces, peers, desires, purpose)
    - stimulus: the triggering event (message, timer, observation)
    - opts: options like :model, :temperature

  ## Returns
    {response_text, list_of_actions, traces_to_record}
  """
  @spec think(map(), String.t() | map(), keyword()) :: {:ok, think_result()} | {:error, term()}
  def think(state, stimulus, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, 0.7)

    prompt = PromptBuilder.build(state, stimulus)

    case call_ollama(model, prompt, temperature) do
      {:ok, response} ->
        {actions, traces} = parse_response(response, state)
        {:ok, {response, actions, traces}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lightweight think for simple stimulus-response without full reasoning.
  Uses smaller context window and faster parsing.
  """
  @spec quick_think(map(), String.t(), keyword()) :: {:ok, action()} | {:error, term()}
  def quick_think(state, stimulus, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)

    prompt = PromptBuilder.build_quick(state, stimulus)

    case call_ollama(model, prompt, 0.3) do
      {:ok, response} ->
        action = parse_single_action(response)
        {:ok, action}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if Ollama is available.
  """
  @spec available?() :: boolean()
  def available? do
    case :httpc.request(:get, {~c"#{@ollama_url}/api/tags", []}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  end

  @doc """
  List available models from Ollama.
  """
  @spec list_models() :: {:ok, [String.t()]} | {:error, term()}
  def list_models do
    case :httpc.request(:get, {~c"#{@ollama_url}/api/tags", []}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"models" => models}} ->
            {:ok, Enum.map(models, & &1["name"])}
          _ ->
            {:ok, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Call Ollama generate API
  defp call_ollama(model, prompt, temperature) do
    # Ensure inets is started
    :inets.start()
    :ssl.start()

    body = Jason.encode!(%{
      model: model,
      prompt: prompt,
      stream: false,
      options: %{
        temperature: temperature,
        num_predict: 512
      }
    })

    request = {
      ~c"#{@ollama_url}/api/generate",
      [],
      ~c"application/json",
      body
    }

    case :httpc.request(:post, request, [{:timeout, @timeout}], []) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(to_string(response_body)) do
          {:ok, %{"response" => response}} ->
            {:ok, String.trim(response)}
          {:ok, other} ->
            {:error, {:unexpected_response, other}}
          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http_error, status, to_string(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # Parse LLM response into structured actions
  defp parse_response(response, state) do
    lines = String.split(response, "\n", trim: true)

    {actions, traces} = Enum.reduce(lines, {[], []}, fn line, {acts, trs} ->
      case parse_action_line(line, state) do
        {:action, action} -> {[action | acts], trs}
        {:trace, trace} -> {acts, [trace | trs]}
        :skip -> {acts, trs}
      end
    end)

    {Enum.reverse(actions), Enum.reverse(traces)}
  end

  defp parse_action_line(line, state) do
    cond do
      # RECORD_TRACE:purpose:hint_key=hint_value
      String.starts_with?(line, "RECORD_TRACE:") ->
        case parse_record_trace(line) do
          {:ok, purpose, hints} -> {:action, {:record_trace, purpose, hints}}
          :error -> :skip
        end

      # QUERY_PEER:peer_id:purpose
      String.starts_with?(line, "QUERY_PEER:") ->
        case String.split(line, ":", parts: 3) do
          [_, peer_id, purpose] ->
            {:action, {:query_peer, String.trim(peer_id), String.to_atom(String.trim(purpose))}}
          _ -> :skip
        end

      # SHARE_TRACE:peer_id:trace_id
      String.starts_with?(line, "SHARE_TRACE:") ->
        case String.split(line, ":", parts: 3) do
          [_, peer_id, trace_id] ->
            {:action, {:share_trace, String.trim(peer_id), String.trim(trace_id)}}
          _ -> :skip
        end

      # UPDATE_DESIRE:new desire text
      String.starts_with?(line, "UPDATE_DESIRE:") ->
        desire = String.replace_prefix(line, "UPDATE_DESIRE:", "") |> String.trim()
        {:action, {:update_desire, desire}}

      # RESPOND:message to send back
      String.starts_with?(line, "RESPOND:") ->
        msg = String.replace_prefix(line, "RESPOND:", "") |> String.trim()
        {:action, {:respond, msg}}

      # THOUGHT:reasoning (record as trace)
      String.starts_with?(line, "THOUGHT:") ->
        thought = String.replace_prefix(line, "THOUGHT:", "") |> String.trim()
        {:trace, %{purpose: :thought, hints: %{content: thought}}}

      # OBSERVATION:something noticed
      String.starts_with?(line, "OBSERVATION:") ->
        obs = String.replace_prefix(line, "OBSERVATION:", "") |> String.trim()
        {:trace, %{purpose: :observation, hints: %{content: obs}}}

      true ->
        :skip
    end
  end

  defp parse_record_trace(line) do
    case String.split(line, ":", parts: 3) do
      [_, purpose, hints_str] ->
        purpose_atom = purpose |> String.trim() |> String.to_atom()
        hints = parse_hints(hints_str)
        {:ok, purpose_atom, hints}
      [_, purpose] ->
        {:ok, purpose |> String.trim() |> String.to_atom(), %{}}
      _ ->
        :error
    end
  end

  defp parse_hints(hints_str) do
    hints_str
    |> String.split(",")
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k) |> String.to_atom(), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp parse_single_action(response) do
    response
    |> String.split("\n", trim: true)
    |> Enum.find_value(:noop, fn line ->
      case parse_action_line(line, %{}) do
        {:action, action} -> action
        _ -> nil
      end
    end)
  end
end
