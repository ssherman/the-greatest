# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Lists::SimplePenaltySummaryComponentTest < ViewComponent::TestCase
  test "renders penalties when calculated_weight_details present" do
    ranked_list = ::OpenStruct.new(
      calculated_weight_details: {
        "penalties" => [
          {"penalty_name" => "Age", "value" => 5.0},
          {"penalty_name" => "Size", "value" => 15.0}
        ],
        "quality_bonus" => {"applied" => false}
      }
    )

    render_inline(Lists::SimplePenaltySummaryComponent.new(ranked_list: ranked_list))

    assert_text "Penalties Applied:"
    assert_text "Age: 5.0%"
    assert_text "Size: 15.0%"
  end

  test "renders quality bonus when applied" do
    ranked_list = ::OpenStruct.new(
      calculated_weight_details: {
        "penalties" => [],
        "quality_bonus" => {"applied" => true}
      }
    )

    render_inline(Lists::SimplePenaltySummaryComponent.new(ranked_list: ranked_list))

    assert_text "High Quality Source Bonus Applied"
  end

  test "renders fallback when calculated_weight_details blank" do
    ranked_list = ::OpenStruct.new(calculated_weight_details: nil)

    render_inline(Lists::SimplePenaltySummaryComponent.new(ranked_list: ranked_list))

    assert_text "Weight calculation details not available."
  end
end
