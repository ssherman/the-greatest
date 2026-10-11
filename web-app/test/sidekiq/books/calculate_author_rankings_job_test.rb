require "test_helper"

module Books
  class CalculateAuthorRankingsJobTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:books_authors_global)
    end

    test "requests a refresh of the primary author configuration instead of calculating inline" do
      ::Services::RankingConfigurations::RequestRefresh.expects(:call).with(config: @config).returns(
        ::Services::RankingConfigurations::RequestRefresh::Result.new(success?: true, data: {}, errors: [])
      )
      Books::Authors::RankingConfiguration.any_instance.expects(:calculate_rankings).never

      Books::CalculateAuthorRankingsJob.new.perform
    end

    test "a refresh already queued or running is not an error and queues nothing" do
      @config.update_columns(refresh_status: RankingConfiguration.refresh_statuses[:running], refresh_requested_at: Time.current)

      # A global configuration enqueues through RefreshJob.set(queue:), not
      # RefreshJob.perform_async, so count the fake queue rather than expect on
      # the class method -- an expectation there could never fire.
      Sidekiq::Testing.fake! do
        ::RankingConfigurations::RefreshJob.clear

        assert_nothing_raised { Books::CalculateAuthorRankingsJob.new.perform }
        assert_empty ::RankingConfigurations::RefreshJob.jobs
      end
    end

    test "raises when there is no primary author configuration" do
      @config.update!(primary: false)

      assert_raises(RuntimeError) { Books::CalculateAuthorRankingsJob.new.perform }
    end
  end
end
