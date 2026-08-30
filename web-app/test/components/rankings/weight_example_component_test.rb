require "test_helper"

module Rankings
  class WeightExampleComponentTest < ViewComponent::TestCase
    setup do
      @example = Services::RankingConfiguration::ExplainerData::WorkedExample.new(
        list: lists(:books_list),
        weight: 70,
        item_count: 26,
        penalties: [
          {name: "List: only covers 1 specific country", value: 20},
          {name: "Voters: Unknown Names", value: 5}
        ],
        penalty_before_bonus: 45.0,
        penalty_after_bonus: 30.0,
        quality_bonus_applied: true
      )
    end

    test "renders the list name and its final weight" do
      render_inline(WeightExampleComponent.new(example: @example))

      assert_text lists(:books_list).name
      assert_text "70"
    end

    test "renders each penalty with its value" do
      render_inline(WeightExampleComponent.new(example: @example))

      assert_text "List: only covers 1 specific country"
      assert_text "20"
      assert_text "Voters: Unknown Names"
    end

    test "mentions the quality bonus when it was applied" do
      render_inline(WeightExampleComponent.new(example: @example))

      assert_text(/high-quality source/i)
    end

    test "omits the quality bonus line when it was not applied" do
      @example.quality_bonus_applied = false
      @example.penalty_after_bonus = 45.0

      render_inline(WeightExampleComponent.new(example: @example))

      assert_no_text(/high-quality source/i)
    end

    test "renders nothing when there is no example" do
      render_inline(WeightExampleComponent.new(example: nil))

      assert_no_selector "table"
    end
  end
end
