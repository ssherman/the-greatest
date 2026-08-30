require "test_helper"

module Rankings
  class PenaltyTableComponentTest < ViewComponent::TestCase
    setup do
      @group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: "voter_expertise",
        title: "Who voted",
        penalties: [penalties(:cross_media_penalty)]
      )
    end

    test "renders the group heading" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_selector "h3", text: "Who voted"
    end

    test "renders each penalty name and description" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_text penalties(:cross_media_penalty).name
      assert_text penalties(:cross_media_penalty).description
    end

    test "renders nothing when there are no groups" do
      render_inline(PenaltyTableComponent.new(groups: []))

      assert_no_selector "h3"
    end

    test "renders a details element per group so the tables start collapsed" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_selector "details"
    end
  end
end
