require "test_helper"

module Services
  module EnrichmentQueue
    class SubmitTest < ActiveSupport::TestCase
      setup do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        @user = users(:admin_user)
        @row = ::EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: "books.test_type", reason: "missing",
          status: :claimed, lease_token: "lease-1", lease_expires_at: 10.minutes.from_now)
      end

      teardown { EnrichmentQueueTestType.reset! }

      def submit(**overrides)
        Submit.call(request: @row, lease_token: "lease-1", answer: {"value" => "x"},
          sources: ["https://example.org/a"], note: "found it", user: @user, **overrides)
      end

      test "stores the answer, marks the row submitted and queues the apply job" do
        Sidekiq::Testing.fake! do
          assert_difference -> { ::EnrichmentQueue::ApplyJob.jobs.size }, 1 do
            assert submit.success?
          end
        end
        @row.reload
        assert_equal ["submitted", {"value" => "x"}, ["https://example.org/a"], "found it", @user.id, "api", "lease-1"],
          [@row.status, @row.answer, @row.sources, @row.note, @row.resolved_by_id, @row.resolved_via, @row.lease_token]
        assert @row.resolved_at.present?
      end

      test "a lease taken over by another batch is a conflict and writes nothing" do
        @row.update!(lease_token: "lease-2")
        result = submit
        assert_equal :conflict, result.errors.first[:code]
        assert @row.reload.claimed?
        assert_nil @row.answer
      end

      test "a wrong token is a conflict even when the answer is also malformed" do
        result = submit(lease_token: "nope", answer: {"value" => 3})
        assert_equal :conflict, result.errors.first[:code]
      end

      test "an expired lease nobody took over is still accepted" do
        @row.update!(lease_expires_at: 1.minute.ago)
        Sidekiq::Testing.fake! { assert submit.success? }
      end

      test "the same submit twice is accepted once and queues one job" do
        Sidekiq::Testing.fake! do
          submit
          assert_no_difference -> { ::EnrichmentQueue::ApplyJob.jobs.size } do
            assert submit.success?
          end
        end
      end

      test "a submitted row with another token is a conflict" do
        Sidekiq::Testing.fake! { submit }
        assert_equal :conflict, submit(lease_token: "lease-2").errors.first[:code]
      end

      test "a pending, done or skipped row is a conflict" do
        %i[pending done skipped].each do |status|
          @row.update!(status: status)
          assert_equal :conflict, submit.errors.first[:code], status
        end
      end

      test "a stale in-memory row loses the guarded update and is answered from the stored row" do
        stale = ::EnrichmentRequest.find(@row.id)
        Sidekiq::Testing.fake! do
          submit
          assert_no_difference -> { ::EnrichmentQueue::ApplyJob.jobs.size } do
            assert submit(request: stale).success?
          end
        end
        @row.reload.update!(status: :done)
        assert_equal :conflict, submit(request: stale).errors.first[:code]
      end

      test "an answer that does not match the type's schema is invalid and leaves the row claimed" do
        result = submit(answer: {"value" => 3, "extra" => true})
        assert_equal :invalid, result.errors.first[:code]
        assert result.errors.first[:detail].present?
        assert @row.reload.claimed?
      end

      test "an answer that is not a hash is invalid" do
        assert_equal :invalid, submit(answer: "x").errors.first[:code]
      end

      test "sources must be 1 to 20 http or https urls" do
        [[], ["ftp://x"], ["not a url"], ["https://example.org/" + "a" * 2000], Array.new(21) { "https://example.org/#{it}" }, "https://example.org", [3]].each do |sources|
          assert_equal :invalid, submit(sources: sources).errors.first[:code], sources.inspect.first(40)
        end
      end

      test "an oversized answer or note is invalid" do
        assert_equal :invalid, submit(answer: {"value" => "x" * 50_001}).errors.first[:code]
        assert_equal :invalid, submit(note: "n" * 1_001).errors.first[:code]
        assert @row.reload.claimed?
      end
    end
  end
end
