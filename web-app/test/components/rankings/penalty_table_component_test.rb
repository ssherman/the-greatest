require "test_helper"

module Rankings
  class PenaltyTableComponentTest < ViewComponent::TestCase
    setup do
      @configuration = ranking_configurations(:books_global)
      @entry = Services::RankingConfiguration::ExplainerData::PenaltyEntry.new(
        penalty: penalties(:cross_media_penalty),
        values: {@configuration => 15}
      )
      @group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: "voter_expertise",
        title: "Who voted",
        penalties: [@entry]
      )
    end

    def render_component(groups:, configurations: [@configuration])
      render_inline(PenaltyTableComponent.new(groups: groups, configurations: configurations))
    end

    test "renders the group heading" do
      render_component(groups: [@group])

      assert_selector "h3", text: "Who voted"
    end

    test "renders intro prose above the group, keyed by category" do
      render_component(groups: [@group])

      assert_text(/Who chose the entries matters more than almost anything else/)
    end

    test "renders the fallback intro for the uncategorized Other group" do
      other_group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: nil,
        title: "Other",
        penalties: [@entry]
      )

      render_component(groups: [other_group])

      assert_text "Adjustments that have not yet been sorted into a category."
    end

    test "renders each penalty name, description and reduction value" do
      render_component(groups: [@group])

      assert_text penalties(:cross_media_penalty).name
      assert_text penalties(:cross_media_penalty).description
      assert_text "15%"
    end

    test "renders a single generic 'Reduction' heading for one configuration" do
      # The table starts collapsed inside a <details>, so its rows are not
      # "visible" to Capybara's default (visible-only) finders -- assert_text
      # searches full page text regardless, which is what the pre-existing
      # tests in this file already rely on for content inside the table.
      render_component(groups: [@group])

      assert_text "Reduction"
      assert_no_text "Albums"
    end

    test "renders a dash for a penalty with no value on the only configuration shown" do
      entry = Services::RankingConfiguration::ExplainerData::PenaltyEntry.new(
        penalty: penalties(:cross_media_penalty),
        values: {@configuration => nil}
      )
      group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: "voter_expertise",
        title: "Who voted",
        penalties: [entry]
      )

      render_component(groups: [group])

      assert_text "—"
    end

    test "renders one column per configuration, headed by its media_noun_plural, when more than one is passed" do
      albums = ranking_configurations(:music_albums_global)
      songs = ranking_configurations(:music_songs_global)
      entry = Services::RankingConfiguration::ExplainerData::PenaltyEntry.new(
        penalty: penalties(:music_penalty),
        values: {albums => 22, songs => 20}
      )
      group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: "voter_expertise",
        title: "Who voted",
        penalties: [entry]
      )

      render_component(groups: [group], configurations: [albums, songs])

      assert_text "Albums"
      assert_text "Songs"
      assert_no_text "Reduction"
      assert_text "22%"
      assert_text "20%"
    end

    test "shows a value in one configuration's column and a dash in the other when a penalty is not attached to both" do
      albums = ranking_configurations(:music_albums_global)
      songs = ranking_configurations(:music_songs_global)
      entry = Services::RankingConfiguration::ExplainerData::PenaltyEntry.new(
        penalty: penalties(:global_penalty),
        values: {albums => 15, songs => nil}
      )
      group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: "list_time_scope",
        title: "How much time it covers",
        penalties: [entry]
      )

      render_component(groups: [group], configurations: [albums, songs])

      # Only one row is rendered here, so the plain page-level text search is
      # unambiguous -- no need to scope into the row itself.
      assert_text "15%"
      assert_text "—"
    end

    test "renders nothing when there are no groups" do
      render_component(groups: [])

      assert_empty rendered_content.strip
    end

    test "renders a details element per group so the tables start collapsed" do
      render_component(groups: [@group])

      assert_selector "details"
    end
  end
end
