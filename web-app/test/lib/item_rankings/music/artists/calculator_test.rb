require "test_helper"

module ItemRankings
  module Music
    module Artists
      class CalculatorTest < ActiveSupport::TestCase
        def setup
          @ranking_configuration = ranking_configurations(:music_artists_global)
          @calculator = ItemRankings::Music::Artists::Calculator.new(@ranking_configuration)

          @album_config = ranking_configurations(:music_albums_global)
          @song_config = ranking_configurations(:music_songs_global)

          @album_config.ranked_items.destroy_all
          @song_config.ranked_items.destroy_all

          create_test_ranked_items
        end

        def teardown
          @ranking_configuration.ranked_items.destroy_all
        end

        test "initialize sets ranking configuration" do
          assert_equal @ranking_configuration, @calculator.ranking_configuration
        end

        test "item_type returns Music::Artist" do
          assert_equal "Music::Artist", @calculator.send(:item_type)
        end

        test "list_type raises NotImplementedError" do
          assert_raises(NotImplementedError) do
            @calculator.send(:list_type)
          end
        end

        test "call returns success result with data" do
          result = @calculator.call

          assert result.success?, "Expected success but got errors: #{result.errors}"
          assert_not_nil result.data
          assert_empty result.errors
          assert_instance_of Array, result.data
        end

        test "call creates ranked items in database" do
          @ranking_configuration.ranked_items.destroy_all

          @calculator.call
          @ranking_configuration.reload

          assert @ranking_configuration.ranked_items.any?, "Should have created ranked items"
        end

        test "call calculates rankings based on album and song scores" do
          @calculator.call

          ranked_items = @ranking_configuration.ranked_items.order(:rank)

          assert ranked_items.any?, "Should have created ranked items"

          scores = ranked_items.pluck(:score)
          assert_equal scores.sort.reverse, scores, "Scores should be in descending order"

          ranks = ranked_items.pluck(:rank)
          expected_ranks = (1..ranks.length).to_a
          assert_equal expected_ranks, ranks, "Ranks should be sequential starting from 1"
        end

        test "call aggregates scores from both albums and songs" do
          @calculator.call

          artist = music_artists(:pink_floyd)
          ranked_item = @ranking_configuration.ranked_items.find_by(item: artist)

          assert ranked_item.present?, "Pink Floyd should be ranked"
          assert ranked_item.score > 0, "Pink Floyd should have a score > 0"
        end

        test "call excludes artists with zero scores" do
          artist_with_no_content = ::Music::Artist.create!(
            name: "No Content Artist",
            slug: "no-content-artist",
            kind: :person
          )

          @calculator.call

          ranked_item = @ranking_configuration.ranked_items.find_by(item: artist_with_no_content)
          assert_nil ranked_item, "Artist with no ranked albums/songs should not be ranked"
        end

        test "call updates existing ranked items with upsert" do
          @calculator.call
          @ranking_configuration.reload
          initial_count = @ranking_configuration.ranked_items.count
          initial_created_at = @ranking_configuration.ranked_items.first.created_at

          @calculator.call
          @ranking_configuration.reload

          assert_equal initial_count, @ranking_configuration.ranked_items.count
          assert_equal initial_created_at, @ranking_configuration.ranked_items.first.created_at
        end

        test "call handles missing album configuration" do
          ::Music::Albums::RankingConfiguration.stubs(:default_primary).returns(nil)

          result = @calculator.call

          assert result.success?
          assert_equal [], result.data
        end

        test "call handles missing song configuration" do
          ::Music::Songs::RankingConfiguration.stubs(:default_primary).returns(nil)

          result = @calculator.call

          assert result.success?
          assert_equal [], result.data
        end

        test "call returns error result on exception" do
          @calculator.stubs(:calculate_all_artist_scores).raises(StandardError, "Test error")

          result = @calculator.call

          assert_not result.success?
          assert_nil result.data
          assert_includes result.errors.first, "Test error"
        end

        private

        def create_test_ranked_items
          dark_side = music_albums(:dark_side_of_the_moon)
          animals = music_albums(:animals)

          wish_you_were_here = music_songs(:wish_you_were_here)
          time_song = music_songs(:time)

          RankedItem.create!(
            item: dark_side,
            ranking_configuration: @album_config,
            rank: 1,
            score: 100.0
          )

          RankedItem.create!(
            item: animals,
            ranking_configuration: @album_config,
            rank: 2,
            score: 80.0
          )

          RankedItem.create!(
            item: wish_you_were_here,
            ranking_configuration: @song_config,
            rank: 1,
            score: 50.0
          )

          RankedItem.create!(
            item: time_song,
            ranking_configuration: @song_config,
            rank: 2,
            score: 40.0
          )
        end
      end
    end
  end
end
