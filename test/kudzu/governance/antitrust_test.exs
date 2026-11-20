defmodule Kudzu.Governance.AntitrustTest do
  use ExUnit.Case, async: true

  alias Kudzu.Governance.Antitrust

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
