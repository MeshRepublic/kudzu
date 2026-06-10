defmodule Mix.Tasks.Kudzu.Distill.Demo do
  @shortdoc "Demonstrate Constitution.Distilled against a live expertise silo"

  @moduledoc """
  Pull the relationship triples from a live expertise silo and run
  `Kudzu.Constitution.Distilled.distill/1` against them. Prints the
  distilled constitution's rule summary and exercises `permitted?/2`
  against a few sample actions.

  ## Usage

      mix kudzu.distill.demo                            # default silo
      mix kudzu.distill.demo --silo linux_sysadmin_test_v2
      mix kudzu.distill.demo --api http://titan:4001 --bearer $KUDZU_API_KEY

  The default invocation expects an in-process silo accessible via
  `Kudzu.Silo` — useful when run via `iex -S mix`. Supplying `--api` and
  `--bearer` fetches traces via the live HTTP API (no BEAM coupling).

  This is the vision-completing demo of Phase 4.1: it shows that real
  triples in the `expertise:linux_sysadmin_test_v2` silo can be consumed
  by a real `distill/1` implementation and produce a real constitution
  with interpretable behavior.
  """
  use Mix.Task

  alias Kudzu.Constitution.Distilled

  @default_silo "linux_sysadmin_test_v2"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          silo: :string,
          api: :string,
          bearer: :string,
          limit: :integer
        ]
      )

    silo = Keyword.get(opts, :silo, @default_silo)
    limit = Keyword.get(opts, :limit, 1000)

    traces =
      case Keyword.get(opts, :api) do
        nil ->
          Mix.Task.run("app.start")
          fetch_in_process(silo, limit)

        url ->
          bearer = Keyword.get(opts, :bearer) || System.get_env("KUDZU_API_KEY")

          if is_nil(bearer) do
            Mix.raise("--bearer or KUDZU_API_KEY required when using --api")
          end

          fetch_http(url, silo, bearer, limit)
      end

    Mix.shell().info("Pulled #{length(traces)} traces from silo expertise:#{silo}")

    case Distilled.distill(traces,
           name: String.to_atom("silo_#{silo}"),
           source: %{kind: :silo, domain: silo}
         ) do
      {:error, reason} ->
        Mix.shell().error("Distillation failed: #{inspect(reason)}")

      {:ok, distilled} ->
        print_summary(distilled)
        demo_permission_checks(distilled)
    end
  end

  defp fetch_in_process(silo_domain, limit) do
    case Kudzu.Silo.find(silo_domain) do
      {:error, :not_found} ->
        Mix.raise("Silo expertise:#{silo_domain} not found in this BEAM node")

      {:ok, pid} ->
        traces = Kudzu.Hologram.recall_all(pid)

        traces
        |> Enum.take(limit)
        |> Enum.filter(fn t ->
          match?(%{type: "relationship"}, t.reconstruction_hint) or
            match?(%{"type" => "relationship"}, t.reconstruction_hint)
        end)
    end
  end

  defp fetch_http(api, silo_domain, bearer, limit) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    headers = [
      {~c"Authorization", String.to_charlist("Bearer #{bearer}")},
      {~c"Accept", ~c"application/json"}
    ]

    list_url = String.to_charlist("#{api}/api/v1/holograms")

    case :httpc.request(:get, {list_url, headers}, [timeout: 10_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _resp_headers, body}} ->
        body
        |> Jason.decode!()
        |> Map.get("holograms", [])
        |> find_silo_id(silo_domain)
        |> fetch_traces(api, headers, limit)

      other ->
        Mix.raise("Failed to list holograms: #{inspect(other)}")
    end
  end

  defp find_silo_id(holograms, domain) do
    target = "expertise:#{domain}"

    case Enum.find(holograms, fn h -> h["purpose"] == target end) do
      nil -> Mix.raise("Silo expertise:#{domain} not found")
      h -> h["id"]
    end
  end

  defp fetch_traces(hologram_id, api, headers, limit) do
    url = String.to_charlist("#{api}/api/v1/holograms/#{hologram_id}/traces?limit=#{limit}")

    case :httpc.request(:get, {url, headers}, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _resp_headers, body}} ->
        body
        |> Jason.decode!()
        |> Map.get("traces", [])
        |> Enum.map(&trace_from_json/1)
        |> Enum.filter(fn t ->
          match?(%{"type" => "relationship"}, t.reconstruction_hint)
        end)

      other ->
        Mix.raise("Failed to fetch traces: #{inspect(other)}")
    end
  end

  defp trace_from_json(json) do
    %Kudzu.Trace{
      id: json["id"],
      origin: json["origin"],
      timestamp: json["timestamp"],
      purpose: json["purpose"],
      path: json["path"] || [],
      reconstruction_hint: json["reconstruction_hint"] || %{}
    }
  end

  defp print_summary(distilled) do
    Mix.shell().info("""

    ╭──────────────────────────────────────────────────────────╮
    │ Distilled constitution                                   │
    ╰──────────────────────────────────────────────────────────╯
      name:           #{distilled.name}
      source:         #{inspect(distilled.source)}
      trace_count:    #{distilled.trace_count}
      distilled_at:   #{distilled.distilled_at}
      distinct subjects:  #{map_size(distilled.rules.by_subject)}
      distinct relations: #{map_size(distilled.rules.by_relation)}

    Top 20 relations (most-evidenced behavioral verbs):
    """)

    distilled.rules.top_relations
    |> Enum.with_index(1)
    |> Enum.each(fn {{rel, count}, i} ->
      Mix.shell().info(
        "      #{String.pad_leading(to_string(i), 2)}. #{String.pad_trailing(rel, 30)} #{count}"
      )
    end)

    Mix.shell().info("\n    Top 10 most-talked-about subjects (rule sources):\n")

    distilled.rules.by_subject
    |> Enum.map(fn {subj, triples} -> {subj, length(triples)} end)
    |> Enum.sort_by(fn {_s, n} -> n end, :desc)
    |> Enum.take(10)
    |> Enum.with_index(1)
    |> Enum.each(fn {{subj, count}, i} ->
      Mix.shell().info(
        "      #{String.pad_leading(to_string(i), 2)}. #{String.pad_trailing(subj, 30)} #{count} triples"
      )
    end)

    Mix.shell().info("\n    Sample rules (5 random triples):\n")

    distilled.rules.by_subject
    |> Enum.flat_map(fn {_subj, triples} -> triples end)
    |> Enum.take_random(5)
    |> Enum.each(fn t ->
      Mix.shell().info("      (#{t.subject}, #{t.relation}, #{t.object})")
    end)
  end

  defp demo_permission_checks(distilled) do
    Mix.shell().info("""

    ╭──────────────────────────────────────────────────────────╮
    │ permitted?/2 demo against distilled rules                │
    ╰──────────────────────────────────────────────────────────╯
    """)

    state = %{distilled: distilled, id: "demo_agent"}

    # Pick a known subject from the rules and an unknown one
    known_subject =
      distilled.rules.by_subject
      |> Map.keys()
      |> Enum.find(fn s -> s in ["apt", "systemctl", "iptables", "lvm", "nginx"] end) ||
        distilled.rules.by_subject |> Map.keys() |> List.first()

    scenarios = [
      {{:install, %{subject: known_subject}},
       "action {:install, %{subject: \"#{known_subject}\"}} (well-evidenced subject)"},
      {{:install, %{subject: "totally_unheard_of_widget_xyz"}},
       "action {:install, %{subject: \"totally_unheard_of_widget_xyz\"}} (unknown subject)"},
      {{:think, %{}}, "action {:think, %{}} (no subject — no rule applies)"}
    ]

    Enum.each(scenarios, fn {action, label} ->
      result = Distilled.permitted?(action, state)
      Mix.shell().info("      #{label}")
      Mix.shell().info("        -> #{inspect(result)}\n")
    end)
  end
end
