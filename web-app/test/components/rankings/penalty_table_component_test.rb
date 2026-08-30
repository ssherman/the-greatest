require "test_helper"

module Rankings
  class PenaltyTableComponentTest < ViewComponent::TestCase
    setup do
      @entry = Services::RankingConfiguration::ExplainerData::PenaltyEntry.new(
        penalty: penalties(:cross_media_penalty),
        value: 15
      )
      @group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: "voter_expertise",
        title: "Who voted",
        penalties: [@entry]
      )
    end

    test "renders the group heading" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_selector "h3", text: "Who voted"
    end

    test "renders intro prose above the group, keyed by category" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_text(/Who chose the entries matters more than almost anything else/)
    end

    test "renders the fallback intro for the uncategorized Other group" do
      other_group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: nil,
        title: "Other",
        penalties: [@entry]
      )

      render_inline(PenaltyTableComponent.new(groups: [other_group]))

      assert_text "Adjustments that have not yet been sorted into a category."
    end

    test "renders each penalty name, description and reduction value" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_text penalties(:cross_media_penalty).name
      assert_text penalties(:cross_media_penalty).description
      assert_text "15%"
    end

    test "renders a dash for a penalty with no value on the primary configuration" do
      entry = Services::RankingConfiguration::ExplainerData::PenaltyEntry.new(
        penalty: penalties(:cross_media_penalty),
        value: nil
      )
      group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: "voter_expertise",
        title: "Who voted",
        penalties: [entry]
      )

      render_inline(PenaltyTableComponent.new(groups: [group]))

      assert_text "—"
    end

    test "renders nothing when there are no groups" do
      render_inline(PenaltyTableComponent.new(groups: []))

      assert_empty rendered_content.strip
    end

    test "renders a details element per group so the tables start collapsed" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_selector "details"
    end
  end
end
