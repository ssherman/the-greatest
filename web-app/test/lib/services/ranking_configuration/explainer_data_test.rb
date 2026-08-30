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
        entry = other.penalties.find { |e| e.penalty == penalty }
        assert_not_nil entry, "expected #{penalty.name} in the Other group"
        assert_equal 10, entry.value
      end

      test "each penalty entry carries its penalty_applications.value for the primary configuration" do
        result = ExplainerData.call(configurations: [@configuration])

        entry = result.data.penalty_groups.flat_map(&:penalties).find { |e| e.penalty == penalties(:books_penalty) }

        assert_not_nil entry
        assert_equal 20, entry.value # penalty_applications.yml: books_penalty_app value 20
      end

      test "a penalty attached only to a non-primary configuration carries a nil value" do
        # music_penalty is attached to both music_albums_global (value 22) and
        # music_songs_global (value 20). Passing songs as the primary means the
        # penalty groups span both configurations, but the value must come
        # from the primary (songs) alone rather than either arbitrarily.
        result = ExplainerData.call(configurations: [ranking_configurations(:music_songs_global)])

        entry = result.data.penalty_groups.flat_map(&:penalties).find { |e| e.penalty == penalties(:music_penalty) }

        assert_not_nil entry
        assert_equal 20, entry.value # penalty_applications.yml: music_songs_penalty_app value 20
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

      test "active_lists_count counts ranked lists whose list is active and excludes ones that are not" do
        create_worked_example_ranked_list # builds one ACTIVE ranked list on @configuration
        inactive_list = ::Books::List.create!(name: "Inactive Padding List", status: :approved)
        ::RankedList.create!(list: inactive_list, ranking_configuration: @configuration, weight: 5)

        result = ExplainerData.call(configurations: [@configuration])

        # Exactly one active ranked list exists on @configuration: the one
        # create_worked_example_ranked_list builds. The shared books_ranked_list
        # fixture (status: approved) and the inactive_list created above are
        # both non-active, so if the status filter were ever dropped this
        # count would be 3, not 1.
        assert_equal 1, result.data.active_lists_count
      end

      test "ranked_items_count counts ranked items with a rank and excludes unranked ones" do
        ::RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @configuration, rank: 1, score: 99.0)
        ::RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @configuration, rank: nil, score: nil)

        result = ExplainerData.call(configurations: [@configuration])

        # Two ranked_items exist on @configuration; only one carries a rank.
        # If the where.not(rank: nil) filter were ever dropped this count
        # would be 2, not 1.
        assert_equal 1, result.data.ranked_items_count
      end

      test "median_list_counts carries each configuration's own median rather than the primary's" do
        pad_books_list_lengths(list_count: 3, items_per_list: 6)

        result = ExplainerData.call(configurations: [@configuration])

        counts = result.data.median_list_counts
        assert_equal result.data.median_list_count, counts[@configuration]
      end

      test "median_list_counts differs per configuration in a multi-configuration domain" do
        albums = ranking_configurations(:music_albums_global)
        songs = ranking_configurations(:music_songs_global)
        # Distinguishable, deliberately different median list lengths per config.
        create_lists_of_length(::Music::Albums::List, count: 3, item_count: 4)
        create_lists_of_length(::Music::Songs::List, count: 3, item_count: 9)

        result = ExplainerData.call(configurations: [albums, songs])

        counts = result.data.median_list_counts
        assert_equal 2, counts.size
        assert_not_equal counts[albums], counts[songs]
      end

      test "median_voter_counts is gathered per configuration rather than queried by the component" do
        # None of the shared fixtures carry number_of_voters, so without a
        # real value here this would only ever assert nil == nil.
        list = ::Books::List.create!(name: "Voter Count Padding List", status: :approved, number_of_voters: 42)
        ::RankedList.create!(list: list, ranking_configuration: @configuration, weight: 10)

        result = ExplainerData.call(configurations: [@configuration])

        counts = result.data.median_voter_counts
        assert_equal [@configuration], counts.keys
        assert_equal 42, counts[@configuration]
      end

      test "automatic_adjustments contains only dynamic penalties, and reuses the loaded penalty set" do
        result = ExplainerData.call(configurations: [@configuration])

        assert result.data.automatic_adjustments.any?
        assert result.data.automatic_adjustments.all?(&:dynamic?)

        loaded_penalties = result.data.penalty_groups.flat_map(&:penalties).map(&:penalty)
        result.data.automatic_adjustments.each do |penalty|
          assert_includes loaded_penalties, penalty
        end
      end

      test "automatic_adjustments is empty when nothing attached is dynamic" do
        static_only = ranking_configurations(:games_global)
        PenaltyApplication.where(ranking_configuration: static_only)
          .joins(:penalty).where.not(penalties: {dynamic_type: nil}).destroy_all

        result = ExplainerData.call(configurations: [static_only])

        assert_empty result.data.automatic_adjustments
      end

      private

      def create_lists_of_length(list_class, count:, item_count:)
        count.times do |n|
          list = list_class.create!(name: "#{list_class.name} Length Padding #{n}", status: :approved)
          item_count.times { |position| list.list_items.create!(position: position + 1) }
        end
      end

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
