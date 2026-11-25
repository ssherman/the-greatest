require "test_helper"

module Services
  module Books
    module BookSubmissions
      # Real connections and threads, as in lock_order_test.rb: two agents
      # claiming at once, and a review decision overlapping the list add of a
      # reader's lookup job. Not transactional, because each thread needs its
      # own connection to see the other's locks; every row the tests make is
      # removed in the teardown. Latches decide the order and a lock timeout
      # bounds a failure so it cannot hang the suite.
      class ReviewConcurrencyTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper

        self.use_transactional_tests = false

        TIMEOUT = 10

        # Inert (nil) except inside these tests.
        module Hooks
          class << self
            attr_accessor :before_finish, :after_locks, :while_claiming
          end
        end

        # The list add, entered with nothing locked yet.
        module FinishGate
          private

          def finish(book)
            Hooks.before_finish&.call
            super
          end
        end
        ProcessSubmission.prepend(FinishGate)

        # A decision that has taken its reader and book locks and not yet written.
        module DecisionGate
          private

          def lock_book(*)
            locked = super
            Hooks.after_locks&.call
            locked
          end
        end
        Reject.prepend(DecisionGate)
        Approve.prepend(DecisionGate)

        # A claim that has picked and locked its rows and not yet marked them.
        module ClaimGate
          private

          def mark_claimed(*)
            Hooks.while_claiming&.call
            super
          end
        end
        Claim.prepend(ClaimGate)

        setup do
          stub_review_side_effects
          @admin = users(:admin_user)
          @reader = users(:regular_user)
          @made = {submissions: [], books: [], authors: [], lists: []}
          @paused = Queue.new
          @release = Queue.new
        end

        teardown do
          Hooks.before_finish = Hooks.after_locks = Hooks.while_claiming = nil
          ids = @made[:books].map(&:id)
          ::Books::BookSubmission.where(id: @made[:submissions]).delete_all
          WorkflowRun.where(enrichable_type: "Books::Book", enrichable_id: ids).destroy_all
          UserListItem.where(listable_type: "Books::Book", listable_id: ids).delete_all
          ::Books::UserList.where(id: @made[:lists].map(&:id)).each { |list| UserListItem.where(user_list_id: list.id).delete_all }
          ::Books::UserList.where(id: @made[:lists].map(&:id)).delete_all
          ::Books::BookAuthor.where(book_id: ids).delete_all
          ::Books::Book.where(id: ids).delete_all
          ::Books::Author.where(id: @made[:authors].map(&:id)).delete_all
        end

        def in_thread(&block)
          Thread.new do
            Thread.current.report_on_exception = false
            ActiveRecord::Base.connection_pool.with_connection do
              ActiveRecord::Base.connection.execute("SET lock_timeout = '#{TIMEOUT}s'")
              block.call
            rescue Exception => error # rubocop:disable Lint/RescueException
              error
            end
          end
        end

        def waiting(&block) = ActiveSupport::Dependencies.interlock.permit_concurrent_loads(&block)

        def await(queue) = waiting { queue.pop(timeout: TIMEOUT) } || flunk("timed out waiting for a thread")

        def wait_until_blocked_or_done(thread)
          waiting do
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
            while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
              return true if blocked_backends.positive?
              return false unless thread.alive?

              Thread.pass
            end
            false
          end
        end

        def blocked_backends
          ActiveRecord::Base.uncached do
            ActiveRecord::Base.connection.select_value(
              "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
            ).to_i
          end
        end

        # Committed rows: a provisional book, its author, and the reader's
        # pending submission, still looking up, on a custom list.
        def make_pending(read_item:)
          n = serial
          book = ::Books::Book.create!(title: "Concurrent Review Book #{n}", provisional: true)
          author = ::Books::Author.create!(name: "Concurrent Review Author #{n}", provisional: true)
          ::Books::BookAuthor.create!(book: book, author: author, position: 1)
          list = ::Books::UserList.create!(user: @reader, name: "Concurrent custom #{n}", list_type: :custom)
          UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: book, completed_on: Date.current) if read_item
          submission = ::Books::BookSubmission.create!(
            user: @reader, user_list: list, input_method: :goodreads, goodreads_book_id: 8_000_000 + n, fingerprint: SecureRandom.hex(4),
            status: :looking_up, review_status: :pending, created_book: true, book: book, lease_token: TOKEN, lease_expires_at: 30.minutes.from_now
          )
          @made[:books] << book
          @made[:authors] << author
          @made[:lists] << list
          @made[:submissions] << submission.id
          [submission, book, list]
        end

        # The reader's lookup stops on entering the list step, nothing locked.
        # The decision runs to the point where it holds its locks and stops. The
        # lookup is released and must block behind the decision; then the
        # decision carries on. Returns [decision_thread, lookup_thread].
        def overlap(submission, &decision)
          at_finish = Queue.new
          go = Queue.new
          Hooks.before_finish = -> {
            at_finish << true
            go.pop(timeout: TIMEOUT)
          }
          lookup = in_thread { ProcessSubmission.call(submission: ::Books::BookSubmission.find(submission.id)) }
          await at_finish
          Hooks.before_finish = nil
          Hooks.after_locks = -> {
            @paused << true
            @release.pop(timeout: TIMEOUT)
          }
          decider = in_thread(&decision)
          await @paused
          Hooks.after_locks = nil

          go << true
          assert wait_until_blocked_or_done(lookup), "the lookup never blocked, so the interleaving was not forced"
          @release << true
          [decider, lookup]
        end

        def assert_no_errors(*threads)
          assert_equal [nil] * threads.size, waiting { threads.map(&:value) }.map { it.respond_to?(:message) ? it.message : nil }
        end

        def reject_call(submission)
          Reject.call(submission: ::Books::BookSubmission.find(submission.id), user: @admin, via: "api", lease_token: TOKEN,
            note: "Not a real book", sources: ["https://example.com/x"])
        end

        [true, false].each do |on_read|
          test "a reject overlapping the reader's list add does not deadlock (reader #{on_read ? "on" : "off"} Read)" do
            submission, book, list = make_pending(read_item: on_read)

            decider, lookup = overlap(submission) { reject_call(submission) }

            result = waiting { decider.value }
            assert_no_errors lookup
            assert result.success?, result.errors.inspect
            assert_not ::Books::Book.exists?(book.id)
            assert_equal 0, UserListItem.where(user_list_id: list.id).count
            row = ::Books::BookSubmission.find(submission.id)
            assert_equal ["rejected", "cancelled", nil], [row.review_status, row.status, row.user_list_item_id]
          end
        end

        [true, false].each do |on_read|
          test "an approve overlapping the reader's list add does not deadlock (reader #{on_read ? "on" : "off"} Read)" do
            submission, book, list = make_pending(read_item: on_read)

            decider, lookup = overlap(submission) {
              Approve.call(submission: ::Books::BookSubmission.find(submission.id), user: @admin, via: "api", lease_token: TOKEN,
                note: "Real book", sources: ["https://example.com/x"])
            }

            result = waiting { decider.value }
            assert_no_errors lookup
            assert result.success?, result.errors.inspect
            assert_not book.reload.provisional?
            assert_equal 1, UserListItem.where(user_list_id: list.id, listable: book).count
            row = ::Books::BookSubmission.find(submission.id)
            assert_equal ["approved", "added"], [row.review_status, row.status]
          end
        end

        test "two agents claiming at once are handed no row twice" do
          mine = Array.new(6) { |i| make_pending(read_item: false).first.tap { it.update_columns(created_at: (10.years + (6 - i).days).ago, lease_token: nil, lease_expires_at: nil, status: ::Books::BookSubmission.statuses[:added]) } }
          paused = Queue.new
          release = Queue.new
          Hooks.while_claiming = -> {
            Hooks.while_claiming = nil
            paused << true
            release.pop(timeout: TIMEOUT)
          }

          first = in_thread { Claim.call(user: @admin, limit: 3) }
          await paused
          second = in_thread { Claim.call(user: users(:editor_user), limit: 3) }
          a_done = waiting { second.join(TIMEOUT) }
          assert a_done, "the second claim waited on the first one's rows instead of skipping them"
          release << true

          a, b = waiting { [first.value, second.value] }
          [a, b].each { assert it.success?, it.inspect }
          claimed = (a.data[:items] + b.data[:items]).map(&:id)
          assert_equal 6, claimed.size
          assert_equal claimed.uniq.sort, claimed.sort
          assert_equal mine.map(&:id).sort, claimed.sort
          assert_equal 2, [a, b].map { it.data[:lease_token] }.uniq.size
        end
      end
    end
  end
end
