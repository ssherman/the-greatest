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
        "total_penalty_percentage" => penalty_after,
        "capped_penalty_percentage" => penalty_after,
        "weight_after_penalty" => 100 - penalty_after,
        "weight_after_floor" => 100 - penalty_after
      }
    }
  end

  def capped_details(minimum_weight: nil)
    {
      "penalties" => [
        {"penalty_name" => "Voters: not critics or experts", "value" => 60},
        {"penalty_name" => "List: only covers 1 specific city", "value" => 50}
      ],
      "base_values" => {"base_weight" => 100, "minimum_weight" => minimum_weight || -50},
      "penalty_summary" => {"total_before_quality_bonus" => 110},
      "quality_bonus" => {"applied" => false, "penalty_before" => 110, "penalty_after" => 110},
      "final_calculation" => {
        "total_penalty_percentage" => 110,
        "capped_penalty_percentage" => 100,
        "weight_after_penalty" => 0.0,
        "weight_after_floor" => minimum_weight || 0.0,
        "final_weight" => minimum_weight || 0
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

  test "shows the score and the count while the rows stay closed" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(full_details)))

    assert_text "Weight 15%"
    assert_text "3 things lower it"
    assert_selector "details.collapse:not([open]) > summary", text: "See how this was worked out"
    # A selector, not assert_text: on a rendered fragment only selectors treat a
    # closed details as hidden.
    assert_no_selector "dt", text: "Base weight"
    assert_selector "dt", text: "Base weight", visible: :all
  end

  test "uses the singular for one penalty" do
    details = full_details.merge("penalties" => [{"penalty_name" => "Voters: Unknown Names", "value" => 5.0}])

    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

    assert_text "1 thing lowers it"
  end

  test "no penalties: says nothing lowers it and has nothing to open" do
    [
      full_details.merge("penalties" => []),
      full_details.except("penalties"),
      full_details(quality_bonus_applied: true).merge("penalties" => [])
    ].each do |details|
      render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

      assert_text "Nothing lowers it"
      assert_no_selector "details"
    end
  end

  test "the fallbacks have nothing to open" do
    [nil, ranked_list_with(nil)].each do |ranked_list|
      render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list))

      assert_text "How good is this list?"
      assert_no_selector "details"
    end
  end

  # Some screen readers expose a summary as a button and drop any heading inside it.
  test "the heading is not inside the summary" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(full_details)))

    assert_selector "h2", text: "How good is this list?"
    assert_no_selector "summary h2", visible: :all
  end

  test "renders penalties ordered by value descending regardless of input order" do
    details = full_details.merge("penalties" => [
      {"penalty_name" => "Voters: Unknown Names", "value" => 5.0},
      {"penalty_name" => "List: only covers 1 language", "value" => 20},
      {"penalty_name" => "Voters: not critics or experts", "value" => 60}
    ])

    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(details)))

    penalty_names = page.all("dt", visible: :all).map { |dt| dt.text(:all) } - ["Base weight", "Total penalty", "Final weight"]
    assert_equal ["Voters: not critics or experts", "List: only covers 1 language", "Voters: Unknown Names"], penalty_names
  end

  test "shows the penalty cap when penalties exceed the base weight" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(capped_details)))

    assert_text "Total penalty"
    assert_text "−110%"
    assert_text "Penalty capped at"
    assert_text "−100%"
  end

  test "shows the minimum weight when the floor raises the result" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(capped_details(minimum_weight: 1))))

    assert_text "Penalty capped at"
    assert_text "Raised to the minimum weight"
    assert_text "Final weight"
    assert_text "1%"
  end

  test "omits the cap and floor rows when neither adjustment applies" do
    render_inline(Lists::WeightBreakdownComponent.new(ranked_list: ranked_list_with(full_details)))

    assert_no_text "Penalty capped at"
    assert_no_text "Raised to the minimum weight"
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
