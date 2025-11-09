require "test_helper"

module Actions
  module Admin
    module Music
      class RefreshAllArtistsRankingsTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
        end

        test "should queue job with primary ranking configuration" do
          ranking_config = mock("ranking_config")
          ranking_config.stubs(:id).returns(123)
          ::Music::Artists::RankingConfiguration.stubs(:default_primary).returns(ranking_config)

          ::Music::CalculateAllArtistsRankingsJob.expects(:perform_async).with(123).once

          result = RefreshAllArtistsRankings.call(
            user: @admin_user,
            models: []
          )

          assert result.success?
          assert_equal "All artist rankings queued for recalculation.", result.message
        end

        test "should return error when no primary ranking configuration exists" do
          ::Music::Artists::RankingConfiguration.stubs(:default_primary).returns(nil)

          ::Music::CalculateAllArtistsRankingsJob.expects(:perform_async).never

          result = RefreshAllArtistsRankings.call(
            user: @admin_user,
            models: []
          )

          assert result.error?
          assert_equal "No primary global ranking configuration found for artists.", result.message
        end

        test "should have correct metadata" do
          assert_equal "Refresh All Artists Rankings", RefreshAllArtistsRankings.name
          assert_equal "This will recalculate rankings for ALL artists in the system.", RefreshAllArtistsRankings.message
        end

        test "should only be visible on index view" do
          assert RefreshAllArtistsRankings.visible?(view: :index)
          assert_not RefreshAllArtistsRankings.visible?(view: :show)
          assert_not RefreshAllArtistsRankings.visible?(view: :edit)
        end
      end
    end
  end
end
