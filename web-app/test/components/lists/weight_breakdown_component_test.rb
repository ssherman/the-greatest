# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Lists::WeightBreakdownComponentTest < ViewComponent::TestCase
  def ranked_list_with(details)
    ::OpenStruct.new(calculated_weight_details: details)
  end

  def full_details(quality_bonus_applied: false)
    penalty_after = quality_bonus_applied ? 57 : 85

    {
      "penalties" => [
        {"penalty_name" => "Voters: not critics or experts", "value" => 60},
        {"penalty_name" => "List: only covers 1 language", "value" => 20},
        {"penalty_name" => "Voters: Unknown Names", "value" => 5.0}
      ],
      "base_values" => {"base_weight" => 100},
      "penalty_summary" => {"total_before_quality_bonus" => 85},
      "quality_bonus" => {
        "applied" => quality_bonus_applied,
        "penalty_before" => 85,
        "penalty_after" => penalty_after
      },
      "final_calculation" => {
        "final_weight" => quality_bonus_applied ? 43 : 15,
        "total_penalty_percentage" => penalty_after
      }
    }
  end

  test "renders every penalty with its percentage" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(full_details)))

    assert_text "Voters: not critics or experts"
    assert_text "−60%"
    assert_text "List: only covers 1 language"
    assert_text "−20%"
    assert_text "Voters: Unknown Names"
    assert_text "−5%"
  end

  test "renders base weight, total penalty and final weight" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(full_details)))

    assert_text "Base weight"
    assert_text "100%"
    assert_text "Total penalty"
    assert_text "−85%"
    assert_text "Final weight"
    assert_text "15%"
  end

  test "renders the quality bonus as the penalty reduction when applied" do
    details = full_details(quality_bonus_applied: true)

    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

    assert_text "High quality source bonus"
    assert_text "+28%"
  end

  test "renders the pre-bonus total when the quality bonus is applied" do
    details = full_details(quality_bonus_applied: true)

    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

    assert_text "Total penalty"
    assert_text "−85%"
  end

  test "omits the quality bonus when it was not applied" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(full_details)))

    assert_no_text "High quality source bonus"
  end

  test "renders a fallback when calculated_weight_details is blank" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(nil)))

    assert_text "Weight calculation details not available"
  end

  test "renders a fallback when there is no ranked list at all" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: nil))

    assert_text "This list is not used for any active rankings"
  end

  test "renders no penalty section when the list has none" do
    details = full_details.merge("penalties" => [])

    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

    assert_no_text "What lowers this list's weight"
    assert_text "Final weight"
  end

  test "renders penalties ordered by value descending regardless of input order" do
    details = full_details.merge("penalties" => [
      {"penalty_name" => "Voters: Unknown Names", "value" => 5.0},
      {"penalty_name" => "List: only covers 1 language", "value" => 20},
      {"penalty_name" => "Voters: not critics or experts", "value" => 60}
    ])

    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

    penalty_names = page.all("dt").map(&:text) - ["Base weight", "Total penalty"]
    assert_equal ["Voters: not critics or experts", "List: only covers 1 language", "Voters: Unknown Names"], penalty_names
  end

  test "the fixture's penalty_summary and final_calculation stay internally consistent" do
    [false, true].each do |quality_bonus_applied|
      details = full_details(quality_bonus_applied: quality_bonus_applied)

      itemized_sum = details["penalties"].sum { |p| p["value"] }
      assert_equal details.dig("penalty_summary", "total_before_quality_bonus"), itemized_sum

      assert_equal details.dig("quality_bonus", "penalty_after"), details.dig("final_calculation", "total_penalty_percentage")
    end
  end
end
