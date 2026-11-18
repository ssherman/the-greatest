require "test_helper"

module Services
  module EnrichmentQueue
    class RequeueTest < ActiveSupport::TestCase
      setup do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        @user = users(:admin_user)
        @row = ::EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: "books.test_type", reason: "missing", version: 0)
      end

      teardown { EnrichmentQueueTestType.reset! }

      test "a done, skipped or failed row becomes pending, manual, at the type's version, and is cleared" do
        %i[done skipped failed].each do |status|
          @row.update!(status: status, outcome: "applied", answer: {"value" => "x"}, error: "boom", resolved_by: @user, resolved_via: :api)
          assert Requeue.call(request: @row, user: @user).success?, status
          @row.reload
          assert_equal ["pending", "manual", 1, nil, nil, nil, nil, nil],
            [@row.status, @row.reason, @row.version, @row.outcome, @row.answer, @row.error, @row.resolved_by_id, @row.resolved_via], status
        end
      end

      test "logs who requeued it" do
        @row.update!(status: :done)
        Rails.logger.expects(:info).with("event=enrichment_queue_requeue request_id=#{@row.id} user_id=#{@user.id}")
        Requeue.call(request: @row, user: @user)
      end

      test "a pending, claimed or submitted row is a conflict and is left alone" do
        %i[pending claimed submitted].each do |status|
          @row.update!(status: status)
          result = Requeue.call(request: @row, user: @user)
          assert_not result.success?, status
          assert_equal :conflict, result.errors.first[:code], status
          assert_equal status.to_s, @row.reload.status
        end
      end
    end
  end
end
