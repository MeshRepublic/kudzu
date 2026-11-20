defmodule Kudzu.Governance.AntitrustTest do
  use ExUnit.Case, async: true

  alias Kudzu.Governance.Antitrust

  # Keep in step with test_presets_are_four_fictional_triples in
  # clients/console/tests/test_antitrust.py (the console's PRESETS): change both together.
  @console_presets [
    {"Triggered", {62, 81, 68}, :triggered},
    {"Watch", {55, 80, 78}, :watch},
    {"Not triggered", {22, 75, 72}, :not_triggered},
    {"Boundary", {40, 80, 72}, :watch}
  ]

  test "the four console presets classify as their labels say" do
    for {label, {share, baseline, current}, expected} <- @console_presets do
      assert {:ok, %{result: ^expected}} =
               Antitrust.evaluate(
                 %{
                   market_share: share,
                   baseline_satisfaction: baseline,
                   current_satisfaction: current
                 },
                 %{}
               ),
             label
    end
  end

  test "both metrics met triggers" do
    assert {:ok, %{result: :triggered, satisfaction: %{drop_pct: 16.05}}} =
             Antitrust.evaluate(
               %{market_share: 62, baseline_satisfaction: 81, current_satisfaction: 68},
               %{}
             )
  end

  test "share exactly at threshold counts as met; drop exactly at threshold does not" do
    assert {:ok,
            %{
              result: :watch,
              concentration: %{met: true},
              satisfaction: %{met: false, drop_pct: 10.0}
            }} =
             Antitrust.evaluate(
               %{market_share: 40, baseline_satisfaction: 80, current_satisfaction: 72},
               %{}
             )
  end

  test "drop just above threshold that rounds to it is still met" do
    assert {:ok, %{result: :triggered, satisfaction: %{met: true, drop_pct: 10.0}}} =
             Antitrust.evaluate(
               %{market_share: 50, baseline_satisfaction: 80_000, current_satisfaction: 71_996.8},
               %{}
             )
  end

  test "float noise at an exact 10% drop does not count as met" do
    assert {:ok, %{result: :watch, satisfaction: %{met: false}}} =
             Antitrust.evaluate(
               %{market_share: 50, baseline_satisfaction: 1.3, current_satisfaction: 1.17},
               %{}
             )
  end

  test "neither met" do
    assert {:ok, %{result: :not_triggered}} =
             Antitrust.evaluate(
               %{market_share: 39.9, baseline_satisfaction: 80, current_satisfaction: 79},
               %{}
             )
  end

  test "custom thresholds are honoured" do
    assert {:ok, %{result: :triggered}} =
             Antitrust.evaluate(
               %{market_share: 25, baseline_satisfaction: 80, current_satisfaction: 75},
               %{share: 20, satisfaction_drop: 5}
             )
  end

  test "rising satisfaction is a negative drop, not met" do
    assert {:ok, %{satisfaction: %{met: false, drop_pct: -12.5}}} =
             Antitrust.evaluate(
               %{market_share: 90, baseline_satisfaction: 80, current_satisfaction: 90},
               %{}
             )
  end

  test "default_thresholds" do
    assert Antitrust.default_thresholds() == %{share: 40.0, satisfaction_drop: 10.0}
  end

  for {field, bad} <- [
        {:market_share, -1},
        {:market_share, 101},
        {:market_share, "x"},
        {:baseline_satisfaction, 0},
        {:baseline_satisfaction, nil},
        {:current_satisfaction, -5}
      ] do
    test "rejects #{field}=#{inspect(bad)}" do
      scenario =
        Map.put(
          %{market_share: 50, baseline_satisfaction: 80, current_satisfaction: 70},
          unquote(field),
          unquote(bad)
        )

      assert {:error, {:invalid, unquote(field)}} = Antitrust.evaluate(scenario, %{})
    end
  end
end
