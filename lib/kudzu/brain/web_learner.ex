defmodule Kudzu.Brain.WebLearner do
  @moduledoc """
  Autonomous web learning — searches for knowledge gaps, reads pages,
  distills knowledge into silo relationships. Zero cost.

  Called by the Brain's activity loop when curiosity generates questions
  that Thought.run can't resolve from stored knowledge.
  """

  require Logger

  alias Kudzu.Brain.Tools.Web.{WebSearch, WebRead}
  alias Kudzu.Brain.Distiller

  @max_search_results 5
  @max_read_pages 3
  @max_chains_per_page 20
  @ollama_url "http://localhost:11434"
  @summary_model "llama4:scout"
  @summary_timeout 180_000

  @doc """
  Research a question: search the web, read top results, distill into
  relational knowledge, store in silos.

  Returns {:ok, %{question, pages_read, chains_stored}} or {:error, reason}.
  """
  def research(question, opts \\ []) do
    Logger.info("[WebLearner] Researching: #{String.slice(question, 0, 100)}")

    with {:ok, search_result} <- search(question),
         pages <- read_top_results(search_result, opts),
         chains <- distill_pages(pages) do
      stored = store_chains(chains)
      summaries_stored = store_page_summaries(pages, question)

      Logger.info(
        "[WebLearner] Done: #{length(pages)} pages, #{stored} chains, #{summaries_stored} summaries"
      )

      {:ok, %{question: question, pages_read: length(pages), chains_stored: stored, summaries_stored: summaries_stored}}
    else
      {:error, reason} ->
        Logger.warning("[WebLearner] Research failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Search the web for a query. Delegates to WebSearch tool.
  """
  def search(query) do
    WebSearch.execute(%{"query" => query})
  end

  @doc """
  Read the top N results from a search. Returns list of page maps.
  """
  def read_top_results(%{results: results}, opts) when is_list(results) do
    limit = Keyword.get(opts, :limit, @max_read_pages)

    results
    |> Enum.take(limit)
    |> Enum.map(fn result ->
      url = Map.get(result, :url, Map.get(result, "url", ""))

      if url != "" do
        case WebRead.execute(%{"url" => url}) do
          {:ok, page} -> page
          {:error, reason} ->
            Logger.debug("[WebLearner] Failed to read #{url}: #{inspect(reason)}")
            nil
        end
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def read_top_results(_, _opts), do: []

  @doc """
  Distill pages into relationship triples using the Distiller.
  """
  def distill_pages(pages) do
    silo_domains = get_silo_domains()

    Enum.flat_map(pages, fn page ->
      text = Map.get(page, :text, "")

      if String.length(text) > 50 do
        result = Distiller.distill(text, silo_domains)
        Enum.take(result.chains, @max_chains_per_page)
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Store relationship triples in the web_knowledge silo.
  Returns count of chains stored.
  """
  def store_chains(chains) when is_list(chains) do
    if chains == [] do
      0
    else
      case Kudzu.Silo.create("web_knowledge") do
        {:ok, _pid} ->
          Enum.each(chains, fn {subject, relation, object} ->
            try do
              Kudzu.Silo.store_relationship("web_knowledge", {subject, relation, object})
            catch
              _, _ -> :ok
            end
          end)

          length(chains)

        {:error, reason} ->
          Logger.warning("[WebLearner] Failed to create silo: #{inspect(reason)}")
          0
      end
    end
  end

  def store_chains(_), do: 0

  @doc """
  Generate summaries for pages via Ollama and store as traces.
  Returns count of summaries stored.
  """
  def store_page_summaries(pages, question) do
    case Kudzu.Silo.create("web_knowledge") do
      {:ok, pid} ->
        pages
        |> Enum.filter(fn page ->
          text = Map.get(page, :text, "")
          String.length(text) > 100
        end)
        |> Enum.reduce(0, fn page, count ->
          text = Map.get(page, :text, "")
          title = Map.get(page, :title, "")
          url = Map.get(page, :url, "")

          summary_result = try do
              summarize_with_ollama(text)
            rescue
              _ -> {:error, :crashed}
            catch
              :exit, _ -> {:error, :crashed}
            end
          case summary_result do
            {:ok, summary} ->
              Kudzu.Hologram.record_trace(pid, :discovery, %{
                type: "page_summary",
                url: url,
                title: title,
                summary: summary,
                content: summary,
                question: question
              })
              count + 1

            {:error, _reason} ->
              snippet = text |> String.slice(0, 500) |> String.trim()
              if String.length(snippet) > 50 do
                Kudzu.Hologram.record_trace(pid, :discovery, %{
                  type: "page_summary",
                  url: url,
                  title: title,
                  summary: snippet,
                  content: snippet,
                  question: question
                })
                count + 1
              else
                count
              end
          end
        end)

      {:error, _reason} ->
        0
    end
  end

  defp summarize_with_ollama(text) do
    :inets.start()
    excerpt = String.slice(text, 0, 4000)
    prompt = "Summarize the following text in 2-3 concise paragraphs. Focus on key facts, concepts, and relationships. Be factual and specific.\n\nText:\n#{excerpt}\n\nSummary:"

    body = Jason.encode!(%{
      model: @summary_model,
      prompt: prompt,
      stream: false,
      options: %{num_predict: 500, temperature: 0.3},
      keep_alive: "10m"
    })

    request = {~c"#{@ollama_url}/api/generate", [], ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, @summary_timeout}], []) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(to_string(response_body)) do
          {:ok, %{"response" => summary}} ->
            trimmed = String.trim(summary)
            if String.length(trimmed) > 20, do: {:ok, trimmed}, else: {:error, :empty_summary}
          _ ->
            {:error, :parse_failed}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp get_silo_domains do
    try do
      case Kudzu.Silo.list() do
        domains when is_list(domains) ->
          Enum.map(domains, fn
            {domain, _, _} -> domain
            domain when is_binary(domain) -> domain
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end
    catch
      _, _ -> []
    end
  end
end
