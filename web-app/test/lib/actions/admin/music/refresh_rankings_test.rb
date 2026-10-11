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

        def refresh_result(success:, reason: nil, errors: [])
          ::Services::RankingConfigurations::RequestRefresh::Result.new(
            success?: success, data: {ranking_configuration: @ranking_config, reason: reason}, errors: errors
          )
        end

        test "requests a refresh of the configuration" do
          ::Services::RankingConfigurations::RequestRefresh.expects(:call)
            .with(config: @ranking_config).returns(refresh_result(success: true))

          result = RefreshRankings.new(user: @user, models: [@ranking_config]).call

          assert result.success?
          assert_equal "Ranking calculation queued for #{@ranking_config.name}.", result.message
        end

        test "warns instead of claiming success when a run is already queued or running" do
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call)
            .returns(refresh_result(success: false, reason: :already_running,
              errors: [::Services::RankingConfigurations::RequestRefresh::ALREADY_RUNNING]))

          result = RefreshRankings.new(user: @user, models: [@ranking_config]).call

          assert result.warning?
          assert_equal "A ranking calculation is already queued or running for #{@ranking_config.name}.", result.message
        end

        test "reports an error when the refresh could not be queued" do
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call)
            .returns(refresh_result(success: false, reason: :enqueue_failed,
              errors: [::Services::RankingConfigurations::RequestRefresh::ENQUEUE_FAILED]))

          result = RefreshRankings.new(user: @user, models: [@ranking_config]).call

          assert result.error?
          assert_equal ::Services::RankingConfigurations::RequestRefresh::ENQUEUE_FAILED, result.message
        end

        test "a second click while the first is queued only warns, end to end" do
          Sidekiq::Testing.fake! do
            ::RankingConfigurations::RefreshJob.clear

            assert RefreshRankings.call(user: @user, models: [@ranking_config]).success?
            assert RefreshRankings.call(user: @user, models: [::RankingConfiguration.find(@ranking_config.id)]).warning?
            assert_equal 1, ::RankingConfigurations::RefreshJob.jobs.size
          end
        end
      end
    end
  end
end
