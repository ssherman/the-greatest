require "test_helper"

module Services
  module EnrichmentQueue
    class RetryApplyTest < ActiveSupport::TestCase
      setup do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        @user = users(:admin_user)
        @row = ::EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: "books.test_type", reason: "missing", version: 1)
        ::EnrichmentQueue::ApplyJob.jobs.clear
      end

      teardown do
        EnrichmentQueueTestType.reset!
        ::EnrichmentQueue::ApplyJob.jobs.clear
      end

      def fail_with_answer
        @row.update!(status: :failed, error: "model outage", answer: {"value" => "x"}, sources: ["https://example.org/a"],
          note: "n", resolved_by: @user, resolved_via: :api, resolved_at: 1.day.ago)
      end

      test "a failed row with an answer is submitted again, keeps its answer and queues one job" do
        fail_with_answer
        Sidekiq::Testing.fake! do
          result = RetryApply.call(request: @row, user: @user)
          assert result.success?
          assert_equal 1, ::EnrichmentQueue::ApplyJob.jobs.size
          assert_equal [@row.id], ::EnrichmentQueue::ApplyJob.jobs.last["args"]
        end
        @row.reload
        assert_equal ["submitted", nil, {"value" => "x"}, ["https://example.org/a"], "n", @user.id, "api"],
          [@row.status, @row.error, @row.answer, @row.sources, @row.note, @row.resolved_by_id, @row.resolved_via]
        assert_in_delta Time.current, @row.resolved_at, 5.seconds
      end

      test "logs who retried it" do
        fail_with_answer
        Rails.logger.expects(:info).with("event=enrichment_queue_retry_apply request_id=#{@row.id} user_id=#{@user.id}")
        Sidekiq::Testing.fake! { RetryApply.call(request: @row, user: @user) }
      end

      test "a failed row with no answer is a conflict and queues nothing" do
        @row.update!(status: :failed, error: "boom")
        Sidekiq::Testing.fake! do
          result = RetryApply.call(request: @row, user: @user)
          assert_not result.success?
          assert_equal :conflict, result.errors.first[:code]
          assert_empty ::EnrichmentQueue::ApplyJob.jobs
        end
        assert @row.reload.failed?
      end

      test "a row submitted 5 minutes ago is a conflict and queues nothing" do
        @row.update!(status: :submitted, answer: {"value" => "x"}, resolved_at: 5.minutes.ago)
        Sidekiq::Testing.fake! do
          result = RetryApply.call(request: @row, user: @user)
          assert_not result.success?
          assert_equal :conflict, result.errors.first[:code]
          assert_match(/still being applied/, result.errors.first[:detail])
          assert_empty ::EnrichmentQueue::ApplyJob.jobs
        end
      end

      test "a row submitted 20 minutes ago queues a job and moves resolved_at to now" do
        @row.update!(status: :submitted, answer: {"value" => "x"}, resolved_at: 20.minutes.ago)
        Sidekiq::Testing.fake! do
          assert RetryApply.call(request: @row, user: @user).success?
          assert_equal 1, ::EnrichmentQueue::ApplyJob.jobs.size
        end
        @row.reload
        assert @row.submitted?
        assert_in_delta Time.current, @row.resolved_at, 5.seconds
        Sidekiq::Testing.fake! do
          assert_not RetryApply.call(request: @row, user: @user).success?, "a second click inside the window is refused"
        end
      end

      test "pending, claimed, done and skipped rows are conflicts" do
        %i[pending claimed done skipped].each do |status|
          @row.update!(status: status, answer: {"value" => "x"})
          Sidekiq::Testing.fake! do
            result = RetryApply.call(request: @row, user: @user)
            assert_not result.success?, status
            assert_equal :conflict, result.errors.first[:code], status
            assert_empty ::EnrichmentQueue::ApplyJob.jobs, status
          end
          assert_equal status.to_s, @row.reload.status
        end
      end

      test "when queueing raises, a failed row is failed again with its original error" do
        fail_with_answer
        ::EnrichmentQueue::ApplyJob.stubs(:perform_async).raises(RedisClient::CannotConnectError, "down")
        result = RetryApply.call(request: @row, user: @user)
        assert_not result.success?
        assert_equal :conflict, result.errors.first[:code]
        assert_match(/could not be queued/, result.errors.first[:detail])
        assert_equal ["failed", "model outage"], [@row.reload.status, @row.error]
      end
    end
  end
end
