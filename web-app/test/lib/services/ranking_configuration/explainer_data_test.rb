require "test_helper"

module Services
  module RankingConfiguration
    class ExplainerDataTest < ActiveSupport::TestCase
      setup do
        @configuration = ranking_configurations(:books_global)
      end

      test "fails when given no configurations" do
        result = ExplainerData.call(configurations: [])

        assert_not result.success?
        assert_includes result.errors, "No ranking configuration available"
      end

      test "succeeds and reports the media noun" do
        result = ExplainerData.call(configurations: [@configuration])

        assert result.success?
        assert_equal "books", result.data.media_nouns
      end

      test "joins media nouns for a multi-configuration domain" do
        result = ExplainerData.call(configurations: [
          ranking_configurations(:music_albums_global),
          ranking_configurations(:music_songs_global)
        ])

        assert_equal "albums and songs", result.data.media_nouns
      end

      test "groups penalties by category in the order the page renders them" do
        result = ExplainerData.call(configurations: [@configuration])

        titles = result.data.penalty_groups.map(&:title)
        assert_equal titles, titles.uniq
        assert_operator result.data.penalty_groups.size, :>, 0
        result.data.penalty_groups.each do |group|
          assert group.penalties.any?, "#{group.title} should not be an empty group"
        end
      end

      test "puts uncategorized penalties in an Other group rather than dropping them" do
        # user_books_penalty is a Books::Penalty, so it is compatible with the
        # books_global (Books::RankingConfiguration) fixture used here.
        # movies_penalty (as named in the original brief) is a Movies::Penalty,
        # and PenaltyApplication rejects applying it to a non-movies
        # configuration -- so it cannot be attached to @configuration.
        penalty = penalties(:user_books_penalty)
        penalty.update!(category: nil)
        PenaltyApplication.create!(penalty: penalty, ranking_configuration: @configuration, value: 10)

        result = ExplainerData.call(configurations: [@configuration])

        other = result.data.penalty_groups.find { |g| g.title == "Other" }
        assert_not_nil other, "expected an Other group"
        assert_includes other.penalties, penalty
      end

      test "score curve shows position is worth far less than presence" do
        # Every Books::List fixture carries just 1-2 list_items, so the real
        # List.median_list_count(type: "Books::List") is 1 -- far shorter than
        # any real book list -- which makes a 2-item synthetic list the score
        # curve scores against, and position swings it far more than presence
        # ever would in production. Padding the median here (rather than in
        # shared fixtures, which regressed Books::ListsQueryTest by adding an
        # extra active ranked list under books_global) keeps this realistic
        # without perturbing anything outside this one test.
        pad_books_list_lengths

        result = ExplainerData.call(configurations: [@configuration])
        curve = result.data.score_curve

        assert_operator curve.top_score, :>, curve.bottom_score
        assert_operator curve.ratio, :<, 2.0
        assert_operator curve.ratio, :>, 1.0
      end

      test "worked example falls back to the heaviest list when the pinned id is absent" do
        # None of the shared ranked_lists fixtures carry calculated_weight_details,
        # and books_ranked_list's list (books_list) isn't active -- so without a
        # real stored calculation, example_scope is always empty. Creating one
        # locally (rather than in shared fixtures, which regressed
        # Books::ListsQueryTest) keeps that change scoped to this test.
        create_worked_example_ranked_list

        result = ExplainerData.call(configurations: [@configuration], example_list_id: 999_999_999)

        assert result.success?
        assert_not_nil result.data.worked_example
      end

      test "worked example is nil when no list carries stored calculation details" do
        create_worked_example_ranked_list
        @configuration.ranked_lists.update_all(calculated_weight_details: nil)

        result = ExplainerData.call(configurations: [@configuration])

        assert result.success?
        assert_nil result.data.worked_example
      end

      private

      def pad_books_list_lengths(list_count: 5, items_per_list: 20)
        list_count.times do |n|
          list = ::Books::List.create!(name: "Median Padding List #{n}", status: :approved)
          items_per_list.times { |position| list.list_items.create!(position: position + 1) }
        end
      end

      def create_worked_example_ranked_list
        list = ::Books::List.create!(name: "Worked Example List", status: :active, high_quality_source: true)

        ::RankedList.create!(
          list: list,
          ranking_configuration: @configuration,
          weight: 85,
          calculated_weight_details: {
            "penalties" => [
              {"penalty_name" => "Western Canon Bias", "value" => 20}
            ],
            "quality_bonus" => {"applied" => true, "penalty_before" => 20, "penalty_after" => 13.33}
          }
        )
      end
    end
  end
end
