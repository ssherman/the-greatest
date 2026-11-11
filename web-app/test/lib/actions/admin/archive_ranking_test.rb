# frozen_string_literal: true

require "test_helper"

module Actions
  module Admin
    class ArchiveRankingTest < ActiveSupport::TestCase
      setup do
        @user = users(:admin_user)
        @config = ranking_configurations(:books_global)
        # The fixtures give the primary no ranked items.
        RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @config, rank: 1, score: 100)
        RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @config, rank: 2, score: 90)
      end

      test "name and message, visible only on the show view" do
        assert_equal "Archive Now", ArchiveRanking.name
        assert_not_empty ArchiveRanking.message
        assert ArchiveRanking.visible?(view: :show)
        assert_not ArchiveRanking.visible?(view: :index)
      end

      test "archives the configuration under the given name" do
        result = ArchiveRanking.call(user: @user, models: [@config], fields: {name: " Before the algorithm change "})

        assert result.success?
        archive = ::Books::RankingArchive.order(:id).last
        assert_equal ["Before the algorithm change", nil, @config.id],
          [archive.name, archive.period, archive.ranking_configuration_id]
        assert_equal %(Archived #{@config.name} as "Before the algorithm change" (#{archive.items_count} items).), result.message
      end

      test "a blank name is an error and archives nothing" do
        assert_no_difference -> { ::Books::RankingArchive.count } do
          result = ArchiveRanking.call(user: @user, models: [@config], fields: {name: "   "})
          assert_not result.success?
          assert_equal "Give the archive a name.", result.message
        end
      end

      test "a 300-character name is an error and archives nothing" do
        assert_no_difference -> { ::Books::RankingArchive.count } do
          result = ArchiveRanking.call(user: @user, models: [@config], fields: {name: "a" * 300})
          assert_not result.success?
          assert_not_empty result.message
        end
      end

      test "a missing name is an error" do
        assert_no_difference -> { ::Books::RankingArchive.count } do
          assert_not ArchiveRanking.call(user: @user, models: [@config]).success?
        end
      end

      test "a configuration with no ranked items is an error" do
        @config.ranked_items.destroy_all

        assert_no_difference -> { ::Books::RankingArchive.count } do
          result = ArchiveRanking.call(user: @user, models: [@config], fields: {name: "Empty"})
          assert_not result.success?
          assert_not_empty result.message
        end
      end

      test "a music configuration is an error" do
        music = ranking_configurations(:music_albums_global)

        assert_no_difference -> { ::Books::RankingArchive.count } do
          result = ArchiveRanking.call(user: @user, models: [music], fields: {name: "Nope"})
          assert_not result.success?
        end
      end

      test "more than one model is an error" do
        assert_no_difference -> { ::Books::RankingArchive.count } do
          result = ArchiveRanking.call(user: @user, models: [@config, ranking_configurations(:books_user)], fields: {name: "Two"})
          assert_not result.success?
        end
      end

      test "a manual archive does not block the monthly one" do
        travel_to Time.utc(2027, 2, 1, 5, 15) do
          assert_difference -> { ::Books::RankingArchive.where(ranking_configuration: @config).count }, 2 do
            assert ArchiveRanking.call(user: @user, models: [@config], fields: {name: "Manual"}).success?
            ::Books::ArchiveMonthlyRankingJob.new.perform
          end
        end

        manual = ::Books::RankingArchive.find_by!(ranking_configuration: @config, name: "Manual")
        monthly = ::Books::RankingArchive.find_by!(ranking_configuration: @config, name: "February 2027")
        assert_equal [nil, Date.new(2027, 2, 1)], [manual.period, monthly.period]
      end
    end
  end
end
