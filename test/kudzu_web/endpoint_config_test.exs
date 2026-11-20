defmodule KudzuWeb.EndpointConfigTest do
  @moduledoc """
  The endpoint's Cowboy idle timeout must outlast a judged proposal evaluation
  (3 to 5 sequential judge samples, each up to 120 s), or the server drops the
  connection while the handler is still working.
  """
  use ExUnit.Case, async: true

  @min_idle_timeout 300_000

  defp idle_timeout(endpoint_config) do
    endpoint_config
    |> Keyword.get(:http, [])
    |> Keyword.get(:protocol_options, [])
    |> Keyword.get(:idle_timeout)
  end

  test "the effective endpoint config sets idle_timeout to at least 300 s" do
    config = Application.get_env(:kudzu, KudzuWeb.MCP.Endpoint)
    timeout = idle_timeout(config)
    # is_integer first: in term order nil (an atom) compares greater than any number
    assert is_integer(timeout) and timeout >= @min_idle_timeout
  end

  test "runtime http: [ip:, port:] merges with the protocol options instead of replacing them" do
    # config/runtime.exs sets `http: [ip: ..., port: ...]` outside :test; runtime
    # config is deep-merged over config/config.exs the same way as below.
    compiled = Config.Reader.read!("config/config.exs", env: :dev, target: :host)
    runtime = [kudzu: [{KudzuWeb.MCP.Endpoint, http: [ip: {100, 70, 67, 110}, port: 4001]}]]
    merged = Config.Reader.merge(compiled, runtime)

    endpoint = merged[:kudzu][KudzuWeb.MCP.Endpoint]
    assert endpoint[:http][:ip] == {100, 70, 67, 110}
    timeout = idle_timeout(endpoint)
    assert is_integer(timeout) and timeout >= @min_idle_timeout
  end
end
