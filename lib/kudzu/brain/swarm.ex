defmodule Kudzu.Brain.Swarm do
  @moduledoc """
  Specialist swarm framework for parallel research.

  Spawns N specialist holograms, each with a focused sub-question
  and its own Runner for autonomous research. Collects findings
  and synthesizes a coherent answer.

  ## Usage

      {:ok, swarm} = Swarm.spawn_specialists("How does Linux handle memory management?", 3)
      # ... wait for runners to complete their cycles ...
      {:ok, %{findings: findings}} = Swarm.collect_findings(swarm.swarm_id)
      {:ok, synthesis} = Swarm.synthesize(swarm.swarm_id)
      Swarm.cleanup(swarm.swarm_id)
  """

  require Logger

  alias Kudzu.{Application, Hologram}
  alias Kudzu.Hologram.Runner

  @default_specialists 3
  @default_cycle_interval 60_000
  @default_max_cycles 10
  @ollama_url "http://localhost:11434"
  @synthesis_model "llama4:scout"
  @synthesis_timeout 180_000

  @doc """
  Spawn a specialist swarm to research a question.

  Options:
    - :constitution - constitutional framework (default :kudzu_evolve)
    - :cycle_interval - ms between runner cycles (default 60s)
    - :max_cycles - max cycles per runner (default 10)
  """
  def spawn_specialists(question, n \\ @default_specialists, opts \\ []) do
    swarm_id = generate_swarm_id()
    sub_questions = generate_sub_questions(question, n)

    Logger.info(
      "[Swarm:#{swarm_id}] Spawning #{n} specialists for: #{String.slice(question, 0, 100)}"
    )

    specialists =
      Enum.with_index(sub_questions)
      |> Enum.map(fn {sub_q, i} ->
        purpose = :"swarm_#{swarm_id}_specialist_#{i}"

        {:ok, holo_pid} =
          Application.spawn_hologram(
            purpose: purpose,
            desires: ["research #{sub_q}", "learn about #{sub_q}"],
            cognition: false,
            constitution: Keyword.get(opts, :constitution, :kudzu_evolve)
          )

        holo_id = Hologram.get_id(holo_pid)

        Hologram.record_trace(holo_pid, :memory, %{
          type: "swarm_assignment",
          swarm_id: swarm_id,
          question: question,
          sub_question: sub_q,
          specialist_index: i
        })

        {:ok, runner_pid} =
          DynamicSupervisor.start_child(
            Kudzu.HologramSupervisor,
            {Runner,
             [
               hologram_pid: holo_pid,
               hologram_id: holo_id,
               swarm_id: swarm_id,
               task: sub_q,
               cycle_interval: Keyword.get(opts, :cycle_interval, @default_cycle_interval),
               max_cycles: Keyword.get(opts, :max_cycles, @default_max_cycles)
             ]}
          )

        %{
          hologram_id: holo_id,
          hologram_pid: holo_pid,
          runner_pid: runner_pid,
          sub_question: sub_q,
          index: i
        }
      end)

    # Connect specialists as peers for knowledge sharing
    connect_peers(specialists)

    swarm = %{
      swarm_id: swarm_id,
      question: question,
      specialists: specialists,
      created_at: DateTime.utc_now()
    }

    store_swarm_info(swarm)

    Logger.info("[Swarm:#{swarm_id}] All #{length(specialists)} specialists running")
    {:ok, swarm}
  end

  @doc """
  Collect findings from all specialists in a swarm.
  """
  def collect_findings(swarm_id) do
    case get_swarm_specialists(swarm_id) do
      [] ->
        {:error, :swarm_not_found}

      specialists ->
        findings =
          Enum.flat_map(specialists, fn spec ->
            try do
              traces =
                Hologram.recall(spec.hologram_pid, :discovery) ++
                  Hologram.recall(spec.hologram_pid, :thought)

              Enum.map(traces, fn trace ->
                %{
                  specialist_index: spec.index,
                  sub_question: spec.sub_question,
                  purpose: trace.purpose,
                  data: trace.reconstruction_hint,
                  timestamp: trace.timestamp
                }
              end)
            catch
              _, _ -> []
            end
          end)

        statuses =
          Enum.map(specialists, fn spec ->
            try do
              Runner.status(spec.runner_pid)
            catch
              _, _ -> %{status: :unknown, hologram_id: spec.hologram_id}
            end
          end)

        {:ok,
         %{
           swarm_id: swarm_id,
           findings: findings,
           statuses: statuses,
           total_findings: length(findings)
         }}
    end
  end

  @doc """
  Synthesize findings from a swarm into a coherent answer.
  """
  def synthesize(swarm_id) do
    case collect_findings(swarm_id) do
      {:ok, %{findings: findings}} when findings != [] ->
        synthesize_findings(swarm_id, findings)

      {:ok, %{findings: []}} ->
        {:error, :no_findings}

      error ->
        error
    end
  end

  @doc """
  Clean up a swarm: stop runners and optionally delete holograms.

  Options:
    - :delete_holograms - also remove specialist holograms (default false)
  """
  def cleanup(swarm_id, opts \\ []) do
    delete_holograms = Keyword.get(opts, :delete_holograms, false)
    specialists = get_swarm_specialists(swarm_id)

    stopped =
      Enum.reduce(specialists, 0, fn spec, count ->
        try do
          if spec.runner_pid && Process.alive?(spec.runner_pid) do
            Runner.stop(spec.runner_pid)
          end

          if delete_holograms do
            Application.stop_hologram(spec.hologram_pid)
          end

          count + 1
        catch
          _, _ -> count
        end
      end)

    Logger.info(
      "[Swarm:#{swarm_id}] Cleaned up #{stopped} specialists (delete_holograms=#{delete_holograms})"
    )

    {:ok, %{stopped: stopped}}
  end

  @doc """
  List active swarms.
  """
  def list_swarms do
    case find_brain_hologram() do
      {:ok, pid} ->
        traces = Hologram.recall(pid, :memory)

        traces
        |> Enum.filter(fn t ->
          hint = t.reconstruction_hint
          is_map(hint) and Map.get(hint, :type) == "swarm_registry"
        end)
        |> Enum.map(fn t -> t.reconstruction_hint end)
        |> Enum.uniq_by(fn info -> info.swarm_id end)

      _ ->
        []
    end
  end

  # Sub-question generation

  defp generate_sub_questions(question, n) do
    case decompose_with_ollama(question, n) do
      {:ok, sub_questions} -> sub_questions
      {:error, _} -> simple_decompose(question, n)
    end
  end

  defp decompose_with_ollama(question, n) do
    prompt =
      "Break this research question into exactly #{n} focused sub-questions that can be researched independently. Each sub-question should cover a distinct aspect. Return ONLY a JSON array of strings, no other text.\n\nQuestion: #{question}\n\nJSON:"

    body =
      Jason.encode!(%{
        model: @synthesis_model,
        prompt: prompt,
        stream: false,
        options: %{num_predict: 500, temperature: 0.3},
        keep_alive: "10m"
      })

    request = {~c"#{@ollama_url}/api/generate", [], ~c"application/json", body}

    try do
      case Kudzu.HTTP.request(:post, request, [{:timeout, @synthesis_timeout}]) do
        {:ok, {{_, 200, _}, _, response_body}} ->
          case Jason.decode(to_string(response_body)) do
            {:ok, %{"response" => response}} ->
              parse_json_array(response, n)

            _ ->
              {:error, :parse_failed}
          end

        _ ->
          {:error, :ollama_unavailable}
      end
    catch
      _, _ -> {:error, :ollama_crashed}
    end
  end

  defp parse_json_array(response, expected_n) do
    trimmed = String.trim(response)

    # Strategy 1: direct decode
    with {:error, _} <- try_decode_array(trimmed) do
      # Strategy 2: extract from code fence
      case Regex.run(~r/```(?:json)?\s*(\[[\s\S]*?\])\s*```/, trimmed) do
        [_, json] ->
          try_decode_array(json)

        nil ->
          # Strategy 3: bare array regex
          case Regex.run(~r/\[\s*"[\s\S]*?"\s*\]/, trimmed) do
            [json] -> try_decode_array(json)
            nil -> {:error, :no_json}
          end
      end
    end
    |> case do
      {:ok, items} ->
        questions = items |> Enum.map(&to_string/1) |> Enum.take(expected_n)
        if length(questions) >= 2, do: {:ok, questions}, else: {:error, :too_few}

      error ->
        error
    end
  end

  defp try_decode_array(str) do
    case Jason.decode(str) do
      {:ok, items} when is_list(items) -> {:ok, items}
      _ -> {:error, :not_array}
    end
  end

  defp simple_decompose(question, n) do
    base = String.trim_trailing(question, "?") |> String.trim()

    angles = [
      "#{base} overview and fundamentals",
      "#{base} practical applications and examples",
      "#{base} common problems and solutions",
      "#{base} best practices and recommendations",
      "#{base} history and evolution"
    ]

    Enum.take(angles, n)
  end

  # Peer connectivity

  defp connect_peers(specialists) do
    pids = Enum.map(specialists, & &1.hologram_pid)

    for a <- pids, b <- pids, a != b do
      try do
        Hologram.introduce_peer(a, b)
      catch
        _, _ -> :ok
      end
    end
  end

  # Swarm registry

  defp store_swarm_info(swarm) do
    case find_brain_hologram() do
      {:ok, pid} ->
        Hologram.record_trace(pid, :memory, %{
          type: "swarm_registry",
          swarm_id: swarm.swarm_id,
          question: swarm.question,
          specialist_ids: Enum.map(swarm.specialists, & &1.hologram_id),
          created_at: DateTime.to_iso8601(swarm.created_at)
        })

      _ ->
        :ok
    end
  end

  defp get_swarm_specialists(swarm_id) do
    Kudzu.Application.list_holograms()
    |> Enum.filter(fn pid ->
      try do
        info = Hologram.info(pid)
        purpose = to_string(info.purpose)
        String.starts_with?(purpose, "swarm_#{swarm_id}_specialist_")
      catch
        _, _ -> false
      end
    end)
    |> Enum.map(fn holo_pid ->
      try do
        info = Hologram.info(holo_pid)
        purpose = to_string(info.purpose)
        index = purpose |> String.split("_") |> List.last() |> String.to_integer()
        holo_id = info.id

        runner_pid = find_runner_for_hologram(holo_id)
        sub_q = get_sub_question(holo_pid, swarm_id)

        %{
          hologram_id: holo_id,
          hologram_pid: holo_pid,
          runner_pid: runner_pid,
          sub_question: sub_q,
          index: index
        }
      catch
        _, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp find_runner_for_hologram(hologram_id) do
    DynamicSupervisor.which_children(Kudzu.HologramSupervisor)
    |> Enum.find_value(fn
      {_, pid, :worker, _} when is_pid(pid) ->
        if Process.alive?(pid) do
          try do
            status = Runner.status(pid)
            if status.hologram_id == hologram_id, do: pid
          catch
            _, _ -> nil
          end
        end

      _ ->
        nil
    end)
  end

  defp get_sub_question(holo_pid, swarm_id) do
    try do
      traces = Hologram.recall(holo_pid, :memory)

      assignment =
        Enum.find(traces, fn t ->
          hint = t.reconstruction_hint

          is_map(hint) and Map.get(hint, :type) == "swarm_assignment" and
            Map.get(hint, :swarm_id) == swarm_id
        end)

      if assignment, do: assignment.reconstruction_hint.sub_question, else: "unknown"
    catch
      _, _ -> "unknown"
    end
  end

  # Synthesis

  defp synthesize_findings(swarm_id, findings) do
    findings_text =
      findings
      |> Enum.sort_by(& &1.timestamp)
      |> Enum.map(fn f ->
        data = f.data

        content =
          cond do
            is_map(data) and Map.has_key?(data, :summary) -> data.summary
            is_map(data) and Map.has_key?(data, :content) -> data.content
            is_map(data) and Map.has_key?(data, :result) -> data.result
            is_map(data) -> inspect(data) |> String.slice(0, 300)
            true -> inspect(data) |> String.slice(0, 300)
          end

        "[Specialist #{f.specialist_index}: #{f.sub_question}]\n#{content}"
      end)
      |> Enum.join("\n\n")
      |> String.slice(0, 6000)

    prompt =
      "Synthesize these research findings from #{length(findings)} specialist agents into a coherent, comprehensive answer. Focus on key facts, relationships, and practical insights. Be specific and factual.\n\nFindings:\n#{findings_text}\n\nSynthesis:"

    body =
      Jason.encode!(%{
        model: @synthesis_model,
        prompt: prompt,
        stream: false,
        options: %{num_predict: 1000, temperature: 0.3},
        keep_alive: "10m"
      })

    request = {~c"#{@ollama_url}/api/generate", [], ~c"application/json", body}

    try do
      case Kudzu.HTTP.request(:post, request, [{:timeout, @synthesis_timeout}]) do
        {:ok, {{_, 200, _}, _, response_body}} ->
          case Jason.decode(to_string(response_body)) do
            {:ok, %{"response" => synthesis}} ->
              trimmed = String.trim(synthesis)

              case find_brain_hologram() do
                {:ok, pid} ->
                  Hologram.record_trace(pid, :discovery, %{
                    type: "swarm_synthesis",
                    swarm_id: swarm_id,
                    synthesis: trimmed,
                    content: trimmed,
                    findings_count: length(findings)
                  })

                _ ->
                  :ok
              end

              {:ok, trimmed}

            _ ->
              {:error, :parse_failed}
          end

        _ ->
          {:error, :ollama_unavailable}
      end
    catch
      _, _ -> {:error, :synthesis_crashed}
    end
  end

  defp find_brain_hologram do
    case Kudzu.Application.find_by_purpose(:kudzu_brain) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :no_brain}
    end
  end

  defp generate_swarm_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
