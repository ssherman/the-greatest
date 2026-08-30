require "test_helper"

module Rankings
  class ScoreCurveComponentTest < ViewComponent::TestCase
    setup do
      @curve = Services::RankingConfiguration::ExplainerData::ScoreCurve.new(
        list_length: 50,
        top_score: 123.1,
        middle_score: 103.2,
        bottom_score: 100.0,
        ratio: 1.23
      )
    end

    test "renders the top and bottom scores" do
      render_inline(ScoreCurveComponent.new(curve: @curve, media_nouns: "books"))

      assert_text "123.1"
      assert_text "100.0"
    end

    test "states the ratio" do
      render_inline(ScoreCurveComponent.new(curve: @curve, media_nouns: "books"))

      assert_text "1.23"
    end

    test "uses the media noun in the copy" do
      render_inline(ScoreCurveComponent.new(curve: @curve, media_nouns: "albums and songs"))

      assert_text(/albums and songs/)
    end

    test "names the configuration's own media noun in the sentence introducing the table" do
      render_inline(ScoreCurveComponent.new(curve: @curve, media_nouns: "albums"))

      assert_text "This is computed from the albums configuration."
    end
  end
end
