require "test_helper"

module Services
  module Books
    module BookSubmissions
      # Real connections and threads: a book delete and ProcessSubmission#finish
      # touching the same book and reader. Not transactional, because each thread
      # needs its own connection to see the other's committed and locked rows; every
      # row the tests make is removed in the ensure. Latches decide the order, and a
      # lock timeout bounds a failure so it cannot hang the suite.
      class LockOrderTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        # Gives a delete a place to stop after its dependents are gone, just before
        # the DELETE of the book row. Inert (nil) except inside these tests.
        module Pause
          class << self
            attr_accessor :after_cascade
          end
        end
        ::Books::Book.before_destroy { Pause.after_cascade&.call }

        # Lets a run stop on entering the list step, with nothing locked yet.
        module FinishGate
          class << self
            attr_accessor :before_finish
          end

          private

          def finish(book)
            FinishGate.before_finish&.call
            super
          end
        end
        ProcessSubmission.prepend(FinishGate)

        # Stops a delete or a merge between its first write to the submission rows
        # and its second, with the book row already locked. That gap is where
        # Postgres re-checks the row's foreign keys and wants the reader's users row.
        module HookPause
          class << self
            attr_accessor :after_first_write

            def fire
              hook = after_first_write
              self.after_first_write = nil
              hook&.call
            end
          end

          module BookHook
            private

            def close_submissions
              super
              HookPause.fire
            end
          end

          module MergerHook
            private

            def merge_submissions
              super
              HookPause.fire
            end
          end
        end
        ::Books::Book.prepend(HookPause::BookHook)
        ::Books::Book::Merger.prepend(HookPause::MergerHook)

        TIMEOUT = 10

        setup do
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          GenerateUserFavoritesListsJob.stubs(:perform_async)
          @user = users(:regular_user)
          @read = user_lists(:regular_user_books_read)
          @custom = ::Books::UserList.create!(user: @user, name: "Lock order custom", list_type: :custom)
          @book = ::Books::Book.create!(title: "Lock Order Book")
          @read_item = UserListItem.create!(user_list: @read, listable: @book)
          @submission = ::Books::BookSubmission.create!(
            user: @user, user_list: @custom, input_method: :goodreads, goodreads_book_id: 4_242_424,
            fingerprint: SecureRandom.hex(4), status: :looking_up, review_status: :not_needed, created_book: false, book: @book
          )
          @paused = Queue.new
          @release = Queue.new
        end

        teardown do
          Pause.after_cascade = nil
          FinishGate.before_finish = nil
          HookPause.after_first_write = nil
          clean_extras
          ::Books::BookSubmission.where(id: @submission.id).delete_all
          UserListItem.where(listable_type: "Books::Book", listable_id: @book.id).delete_all
          ::Books::Book.where(id: @book.id).delete_all
          UserListItem.where(user_list_id: @custom.id).delete_all
          ::Books::UserList.where(id: @custom.id).delete_all
        end

        def in_thread(&block)
          Thread.new do
            Thread.current.report_on_exception = false
            ActiveRecord::Base.connection_pool.with_connection do
              ActiveRecord::Base.connection.execute("SET lock_timeout = '#{TIMEOUT}s'")
              block.call
              nil
            rescue Exception => error # rubocop:disable Lint/RescueException
              error
            end
          end
        end

        # The threads may autoload constants; the main thread must not hold the
        # load interlock while it waits for them.
        def waiting(&block) = ActiveSupport::Dependencies.interlock.permit_concurrent_loads(&block)

        def await(queue) = waiting { queue.pop(timeout: TIMEOUT) } || flunk("timed out waiting for a thread")

        # True once some backend of this database waits on a lock; false if the
        # thread finished first.
        def wait_until_blocked_or_done(thread)
          waiting { poll_until_blocked_or_done(thread) }
        end

        def poll_until_blocked_or_done(thread)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
          while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            return true if blocked_backends.positive?
            return false unless thread.alive?

            Thread.pass
          end
          false
        end

        # Uncached: the same query is polled, and the query cache would answer it once.
        def blocked_backends
          ActiveRecord::Base.uncached do
            ActiveRecord::Base.connection.select_value(
              "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
            ).to_i
          end
        end

        def finish_run(submission = @submission) = ProcessSubmission.call(submission: ::Books::BookSubmission.find(submission.id))

        # A provisional book with a pending row the run is about to put on a list,
        # and a catalog book to merge it into.
        def provisional_setup(on_read: false)
          @extra_books = []
          @provisional = ::Books::Book.create!(title: "Lock Order Provisional", provisional: true)
          @catalog = ::Books::Book.create!(title: "Lock Order Catalog")
          @extra_books.push(@provisional, @catalog)
          UserListItem.create!(user_list: @read, listable: @provisional) if on_read
          @pending = ::Books::BookSubmission.create!(
            user: @user, user_list: @custom, input_method: :goodreads, goodreads_book_id: 4_242_425,
            fingerprint: SecureRandom.hex(4), status: :looking_up, review_status: :pending, created_book: true, book: @provisional
          )
        end

        def clean_extras
          return unless @extra_books

          ids = @extra_books.map(&:id)
          ::Books::BookSubmission.where(id: @pending&.id).delete_all
          UserListItem.where(listable_type: "Books::Book", listable_id: ids).delete_all
          SearchIndexRequest.where(parent_type: "Books::Book", parent_id: ids).delete_all
          RecordRedirect.where(item_type: "Books::Book", from_id: ids).delete_all
          ::Books::Book.where(id: ids).delete_all
        end

        # The run stops on entering the list step with nothing locked; the writer
        # (a delete or a merge) takes the book, makes its first write to the row and
        # stops; the run is released, takes the reader's lock and must block on the
        # book; then the writer carries on. Returns the two threads.
        def interleave(&writer_body)
          at_finish = Queue.new
          go = Queue.new
          FinishGate.before_finish = -> {
            at_finish << true
            go.pop(timeout: TIMEOUT)
          }
          finisher = in_thread { finish_run(@pending) }
          await at_finish
          FinishGate.before_finish = nil
          HookPause.after_first_write = -> {
            @paused << true
            @release.pop(timeout: TIMEOUT)
          }
          writer = in_thread(&writer_body)
          await @paused

          go << true
          assert wait_until_blocked_or_done(finisher), "the run never blocked on the book, so the interleaving was not forced"
          @release << true
          [writer, finisher]
        end

        def assert_no_errors(*threads)
          assert_equal [nil] * threads.size, waiting { threads.map(&:value) }.map { it&.message }
        end

        def merge!
          result = ::Books::Book::Merger.call(source: ::Books::Book.find(@provisional.id), target: ::Books::Book.find(@catalog.id))
          raise result.errors.inspect unless result.success?
        end

        def assert_clean(deleter, finisher)
          errors = waiting { [deleter.value, finisher.value] }
          assert_equal [nil, nil], errors.map { it&.message }
          assert_not ::Books::Book.exists?(@book.id)
          assert_equal 0, UserListItem.where(listable_type: "Books::Book", listable_id: @book.id).count
          assert_nil ::Books::BookSubmission.find(@submission.id).user_list_item_id
        end

        test "a list add that meets a delete already past its cascade waits, finds the book gone and adds nothing" do
          at_finish = Queue.new
          go = Queue.new
          FinishGate.before_finish = -> {
            at_finish << true
            go.pop(timeout: TIMEOUT)
          }
          finisher = in_thread { finish_run }
          await at_finish
          FinishGate.before_finish = nil
          Pause.after_cascade = -> {
            @paused << true
            @release.pop(timeout: TIMEOUT)
          }
          deleter = in_thread { ::Books::Book.find(@book.id).destroy! }
          await @paused
          Pause.after_cascade = nil

          go << true
          assert wait_until_blocked_or_done(finisher), "the run never blocked, so the interleaving was not forced"
          @release << true

          assert_clean deleter, finisher
        end

        test "an admin delete (reader locked first) and a list add for that reader do not deadlock" do
          deleter = in_thread do
            ActiveRecord::Base.transaction do
              ::Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: ::Books::Book.find(@book.id))
              @paused << true
              @release.pop(timeout: TIMEOUT)
              ::Books::Book.find(@book.id).destroy!
            end
          end
          await @paused
          finisher = in_thread { finish_run }

          assert wait_until_blocked_or_done(finisher), "the run never blocked, so the interleaving was not forced"
          @release << true

          assert_clean deleter, finisher
        end

        test "a bare delete of a provisional book with a pending row, reader off Read, and a list add do not deadlock" do
          provisional_setup
          writer, finisher = interleave { ::Books::Book.find(@provisional.id).destroy! }

          assert_no_errors writer, finisher
          @pending.reload
          assert_equal ["cancelled", "rejected", nil, nil], [@pending.status, @pending.review_status, @pending.book_id, @pending.user_list_item_id]
          assert_equal 0, UserListItem.where(user_list_id: @custom.id).count
        end

        [false, true].each do |on_read|
          test "a merge of a provisional book into a catalog book (reader #{on_read ? "on" : "off"} Read) and a list add do not deadlock" do
            provisional_setup(on_read: on_read)
            writer, finisher = interleave { merge! }

            assert_no_errors writer, finisher
            @pending.reload
            assert_equal ["added", "merged", @catalog.id], [@pending.status, @pending.review_status, @pending.book_id]
            assert_equal [@catalog.id], UserListItem.where(user_list_id: @custom.id).pluck(:listable_id)
            assert_equal 0, UserListItem.where(listable_type: "Books::Book", listable_id: @provisional.id).count
          end
        end

        test "the delete locks the book row before anything else and the list add locks the reader before the book" do
          statements = []
          subscriber = ->(*, payload) { statements << payload[:sql] if payload[:name] != "SCHEMA" }

          ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { finish_run }
          book_lock = statements.index { it.include?("books_books") && it.include?("FOR KEY SHARE") }
          user_lock = statements.index { it.include?('FROM "users"') && it.include?("FOR NO KEY UPDATE") }
          assert user_lock && book_lock && user_lock < book_lock, "the reader is locked before the book"

          statements.clear
          ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { ::Books::Book.find(@book.id).destroy! }
          first_lock = statements.index { it.include?('FROM "books_books"') && it.include?("FOR UPDATE") }
          cascade = statements.index { it.start_with?("DELETE", "UPDATE") }
          assert first_lock && cascade && first_lock < cascade, "the book row is locked before the first write"
        end
      end
    end
  end
end
