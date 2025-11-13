require "test_helper"

module Actions
  module Admin
    module Music
      class RefreshRankingsTest < ActiveSupport::TestCase
        setup do
          @user = users(:admin_user)
          @ranking_config = ranking_configurations(:music_albums_global)
          @ranking_config2 = ranking_configurations(:music_albums_secondary)
        end

        # Metadata Tests

        test "name returns correct action name" do
          assert_equal "Refresh Rankings", RefreshRankings.name
        end

        test "message returns correct description" do
          assert_equal "Recalculate rankings using current configuration and weights.", RefreshRankings.message
        end

        test "visible? returns true when view is show" do
          assert RefreshRankings.visible?(view: :show)
        end

        test "visible? returns false when view is index" do
          assert_not RefreshRankings.visible?(view: :index)
        end

        test "visible? returns false when view is not provided" do
          assert_not RefreshRankings.visible?({})
        end

        # Call Tests

        test "returns error when no models provided" do
          action = RefreshRankings.new(user: @user, models: [])
          result = action.call

          assert_not result.success?
          assert_equal "This action can only be performed on a single configuration.", result.message
        end

        test "returns error when multiple models provided" do
          action = RefreshRankings.new(user: @user, models: [@ranking_config, @ranking_config2])
          result = action.call

          assert_not result.success?
          assert_equal "This action can only be performed on a single configuration.", result.message
        end

        test "calls calculate_rankings_async on configuration" do
          @ranking_config.expects(:calculate_rankings_async)

          action = RefreshRankings.new(user: @user, models: [@ranking_config])
          result = action.call

          assert result.success?
        end

        test "returns success message with configuration name" do
          @ranking_config.stubs(:calculate_rankings_async)

          action = RefreshRankings.new(user: @user, models: [@ranking_config])
          result = action.call

          assert result.success?
          assert_equal "Ranking calculation queued for #{@ranking_config.name}.", result.message
        end

        test "can be called using class method" do
          @ranking_config.stubs(:calculate_rankings_async)

          result = RefreshRankings.call(user: @user, models: [@ranking_config])

          assert result.success?
          assert_equal "Ranking calculation queued for #{@ranking_config.name}.", result.message
        end

        test "works with different configuration types" do
          songs_config = ranking_configurations(:music_songs_global)
          songs_config.stubs(:calculate_rankings_async)

          action = RefreshRankings.new(user: @user, models: [songs_config])
          result = action.call

          assert result.success?
          assert_equal "Ranking calculation queued for #{songs_config.name}.", result.message
        end
      end
    end
  end
end
