require "test_helper"

module Services
  module EnrichmentQueue
    class ApplyTest < ActiveSupport::TestCase
      Result = Type::Result

      setup do
        Registry.stubs(:types).returns([EnrichmentQueueTestType])
        @user = users(:admin_user)
        @row = ::EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: "books.test_type", reason: "missing",
          status: :submitted, answer: {"value" => "x"}, lease_token: "lease-1", lease_expires_at: 10.minutes.from_now,
          resolved_by: @user, resolved_via: :api, resolved_at: Time.current)
      end

      teardown do
        EnrichmentQueueTestType.reset!
        Current.reset
      end

      test "a successful apply closes the row with the ledger row and its outcome, and clears the lease" do
        ledger = ::Enrichment.create!(enrichable: @row.enrichable, kind: "books.test_type", mode: :knowledge, outcome: :applied, facts: {})
        EnrichmentQueueTestType.apply_result = Result.new(success?: true, data: {enrichment: ledger, outcome: "applied"}, errors: [])
        assert Apply.call(request_id: @row.id).success?
        @row.reload
        assert_equal ["done", "applied", ledger.id, nil, nil], [@row.status, @row.outcome, @row.enrichment_id, @row.lease_token, @row.lease_expires_at]
      end

      test "a failing apply raises so the job retries, and the row stays submitted" do
        EnrichmentQueueTestType.apply_result = Result.new(success?: false, data: nil, errors: ["chooser failed"])
        error = assert_raises(Apply::Failed) { Apply.call(request_id: @row.id) }
        assert_includes error.message, "chooser failed"
        assert @row.reload.submitted?
      end

      test "a missing row, or one that is not submitted, is a no-op" do
        assert Apply.call(request_id: 0).success?
        @row.update!(status: :done)
        EnrichmentQueueTestType.expects(:apply).never
        assert Apply.call(request_id: @row.id).success?
      end

      test "a row whose record is gone is deleted and is a no-op" do
        book = ::Books::Book.create!(title: "Short lived")
        row = ::EnrichmentRequest.create!(enrichable: book, kind: "books.test_type", reason: "missing", status: :submitted, answer: {"value" => "x"})
        # Without callbacks: Book#destroy would delete the queue row too (dependent: :delete_all).
        ::Books::Book.where(id: book.id).delete_all
        EnrichmentQueueTestType.expects(:apply).never
        assert Apply.call(request_id: row.id).success?
        assert_not ::EnrichmentRequest.exists?(row.id)
      end

      test "fail! marks the row failed with the error, cut to 1,000 characters, and clears the lease" do
        Apply.fail!(request_id: @row.id, error: "x" * 2_000)
        @row.reload
        assert_equal ["failed", 1_000, nil], [@row.status, @row.error.length, @row.lease_token]
      end

      test "fail! leaves a done row alone and ignores a missing one" do
        @row.update!(status: :done)
        Apply.fail!(request_id: @row.id, error: "late")
        assert @row.reload.done?
        assert_nothing_raised { Apply.fail!(request_id: 0, error: "x") }
      end

      test "the acting user and via are set while the type applies" do
        seen = nil
        EnrichmentQueueTestType.stubs(:apply).with { |_| seen = [Current.acting_user, Current.acting_via] }.returns(
          Result.new(success?: true, data: {enrichment: nil, outcome: "applied"}, errors: [])
        )
        Apply.call(request_id: @row.id)
        assert_equal [@user, "api"], seen
      end

      test "the previous acting values are restored after the type raises" do
        Current.acting_user = nil
        Current.acting_via = "admin_ui"
        EnrichmentQueueTestType.stubs(:apply).raises(RuntimeError, "boom")
        assert_raises(RuntimeError) { Apply.call(request_id: @row.id) }
        assert_equal [nil, "admin_ui"], [Current.acting_user, Current.acting_via]
      end

      test "when another worker holds the lock the type is not called, the row stays submitted, and the result is a success" do
        Apply.any_instance.stubs(:acquire_lock).returns(false)
        EnrichmentQueueTestType.expects(:apply).never
        assert Apply.call(request_id: @row.id).success?
        assert @row.reload.submitted?
      end

      test "the row is read after the lock: one closed in the meantime is a no-op" do
        row = @row
        # Stands in for the lock being taken (really taken, so the release has something to release),
        # after another worker closed the row.
        Apply.any_instance.stubs(:acquire_lock).with { |connection|
          row.update_columns(status: ::EnrichmentRequest.statuses.fetch("done"), outcome: "applied")
          connection.select_value("SELECT pg_try_advisory_lock(hashtext('#{Apply::LOCK_NAMESPACE}'), $1::integer)", "test lock", [row.id])
        }.returns(true)
        EnrichmentQueueTestType.expects(:apply).never
        assert Apply.call(request_id: @row.id).success?
        assert_equal ["done", "applied"], [@row.reload.status, @row.outcome]
      end

      test "the advisory lock is held while the type applies and released after a success" do
        held = nil
        held_objid = nil
        EnrichmentQueueTestType.stubs(:apply).with { |_|
          held = advisory_lock_count
          held_objid = advisory_lock_objids
        }.returns(
          Result.new(success?: true, data: {enrichment: nil, outcome: "applied"}, errors: [])
        )
        Apply.call(request_id: @row.id)
        assert_equal [1, [@row.id], 0], [held, held_objid, advisory_lock_count]
      end

      test "the advisory lock is released after the type raises" do
        EnrichmentQueueTestType.stubs(:apply).raises(RuntimeError, "boom")
        assert_raises(RuntimeError) { Apply.call(request_id: @row.id) }
        assert_equal 0, advisory_lock_count
      end

      test "the advisory lock is released after Apply::Failed" do
        EnrichmentQueueTestType.apply_result = Result.new(success?: false, data: nil, errors: ["chooser failed"])
        assert_raises(Apply::Failed) { Apply.call(request_id: @row.id) }
        assert_equal 0, advisory_lock_count
      end

      test "a second call for a row the first finished does not call the type or change the outcome" do
        EnrichmentQueueTestType.apply_result = Result.new(success?: true, data: {enrichment: nil, outcome: "applied"}, errors: [])
        Apply.call(request_id: @row.id)
        EnrichmentQueueTestType.apply_result = Result.new(success?: true, data: {enrichment: nil, outcome: "nothing_to_apply"}, errors: [])
        EnrichmentQueueTestType.expects(:apply).never
        assert Apply.call(request_id: @row.id).success?
        assert_equal ["done", "applied"], [@row.reload.status, @row.outcome]
      end

      test "a successful apply wins over a concurrent fail!: the row ends done with the outcome, the ledger row and no error" do
        row = @row
        ledger = ::Enrichment.create!(enrichable: row.enrichable, kind: "books.test_type", mode: :knowledge, outcome: :applied, facts: {})
        EnrichmentQueueTestType.stubs(:apply).with { |_| Apply.fail!(request_id: row.id, error: "gave up") }.returns(
          Result.new(success?: true, data: {enrichment: ledger, outcome: "applied"}, errors: [])
        )
        assert Apply.call(request_id: @row.id).success?
        @row.reload
        assert_equal ["done", "applied", ledger.id, nil], [@row.status, @row.outcome, @row.enrichment_id, @row.error]
      end

      test "a row re-queued to pending while the type applies stays pending and the call is a no-op" do
        row = @row
        EnrichmentQueueTestType.stubs(:apply).with { |_| row.update_columns(status: ::EnrichmentRequest.statuses.fetch("pending")) }.returns(
          Result.new(success?: true, data: {enrichment: nil, outcome: "applied"}, errors: [])
        )
        result = Apply.call(request_id: @row.id)
        assert result.success?
        assert_nil result.data
        assert_equal ["pending", nil], [@row.reload.status, @row.outcome]
      end

      test "when the unlock raises the result is still returned and the connection is dropped to free the lock" do
        connection = ::EnrichmentRequest.connection
        Apply.any_instance.stubs(:unlock).raises(RuntimeError, "unlock failed")
        # Stubbed: really dropping the test's single transactional connection would end the test's transaction.
        connection.expects(:disconnect!).once
        begin
          assert Apply.call(request_id: @row.id).success?
          assert @row.reload.done?
        ensure
          # The stubbed unlock never ran, so release the real lock by hand.
          connection.uncached { connection.select_value("SELECT pg_advisory_unlock(hashtext('#{Apply::LOCK_NAMESPACE}'), $1::integer)", "test unlock", [@row.id]) }
        end
      end

      test "when the acquire raises the error propagates and the release is still attempted" do
        Apply.any_instance.stubs(:acquire_lock).raises(RuntimeError, "interrupted")
        Apply.any_instance.expects(:unlock).once.returns(true)
        assert_raises(RuntimeError) { Apply.call(request_id: @row.id) }
      end

      test "when the lock is not granted the release is not attempted" do
        Apply.any_instance.stubs(:acquire_lock).returns(false)
        Apply.any_instance.expects(:unlock).never
        Apply.call(request_id: @row.id)
      end

      private

      def advisory_lock_objids
        connection = ::EnrichmentRequest.connection
        connection.uncached do
          connection.select_values("SELECT objid FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()").map(&:to_i)
        end
      end

      def advisory_lock_count
        connection = ::EnrichmentRequest.connection
        connection.uncached do
          connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()").to_i
        end
      end
    end
  end
end
