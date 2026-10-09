# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class RunTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @war = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @got = books_books(:got)
          @clash = books_books(:clash)
          @scope = ::Books::Book.where(id: [@war, @crime, @got, @clash].map(&:id))
          @client = FakeOlClient.new
        end

        # Session locks outlive a test's rolled-back transaction, so start each test clean.
        setup { release_session_locks }
        teardown { release_session_locks }

        def release_session_locks
          ActiveRecord::Base.connection.select_value("SELECT 1 FROM (SELECT pg_advisory_unlock_all()) AS unlocked")
        end

        def no_sleep = ->(_seconds) { flunk "no wait expected" }

        def ok = ApplyBook::Result.new(success?: true, data: nil, errors: [])

        # ApplyBook stand-in: records the order and writes the row a real one would.
        def record_applies(success: true)
          order = []
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            ::Books::OpenLibraryBackfill.create!(book: book, outcome: :keyed, run_id: success ? run_id : "other-run")
            true
          end.returns(ApplyBook::Result.new(success?: success, data: nil, errors: []))
          order
        end

        def rank(book, position)
          ::RankedItem.create!(item: book, ranking_configuration: ranking_configurations(:books_global), rank: position, score: 100 - position)
        end

        def run_backfill(**options)
          Run.call(limit: nil, run_id: "run-1", client: @client, sleeper: no_sleep, scope: @scope, **options)
        end

        # A real second session: the test connection is shared by every
        # pool checkout, and an advisory lock is re-entrant in one session.
        def other_session
          config = ActiveRecord::Base.connection_db_config.configuration_hash
          PG.connect(dbname: config[:database], host: config[:host], port: config[:port], user: config[:username], password: config[:password])
        end

        def with_lock_held_elsewhere
          session = other_session
          assert_equal "t", session.exec("SELECT pg_try_advisory_lock(#{Run::LOCK_KEY})").getvalue(0, 0)
          yield
        ensure
          # Unlock explicitly: the server frees a closed session's locks a moment later.
          session&.exec("SELECT pg_advisory_unlock(#{Run::LOCK_KEY})")
          session&.close
        end

        def assert_lock_free
          session = other_session
          assert_equal "t", session.exec("SELECT pg_try_advisory_lock(#{Run::LOCK_KEY})").getvalue(0, 0)
        ensure
          session&.exec("SELECT pg_advisory_unlock(#{Run::LOCK_KEY})")
          session&.close
        end

        test "a run started while another holds the lock does nothing and says so" do
          ApplyBook.expects(:call).never
          result = nil
          with_lock_held_elsewhere { result = run_backfill }

          assert_not result.success?
          assert_equal({processed: 0, stopped: true, error: "another Open Library backfill run is in progress"}, result.data)
        end

        test "the lock is released after a normal run" do
          record_applies
          run_backfill(limit: 1)

          assert_lock_free
        end

        test "a lost lock is logged with the run id" do
          record_applies
          Run.any_instance.stubs(:unlock).returns(false)
          Rails.logger.expects(:warn).with(regexp_matches(/run-1/)).once

          run_backfill(limit: 1)
        ensure
          ActiveRecord::Base.connection.select_value("SELECT pg_advisory_unlock(#{Run::LOCK_KEY})")
        end

        test "the lock is released when the run raises" do
          ApplyBook.stubs(:call).raises(ActiveRecord::RecordNotUnique, "boom")
          assert_raises(ActiveRecord::RecordNotUnique) { run_backfill }

          assert_lock_free
        end

        test "ranked books come first, by rank, and the run stops after its limit" do
          rank(@got, 2)
          rank(@clash, 1)
          order = record_applies

          result = run_backfill(limit: 2)

          assert_equal [@clash.id, @got.id], order
          assert_equal({processed: 2, stopped: false, error: nil}, result.data)
        end

        def list_book(book, *lists)
          lists.each { |list| ::ListItem.create!(list: list, listable: book, position: 1) }
        end

        test "unranked books are taken by how many lists they are on, most first" do
          list_book(@got, lists(:basic_list), lists(:another_list))
          list_book(@crime, lists(:basic_list))
          order = record_applies

          run_backfill

          assert_equal [@got.id, @crime.id], order.first(2)
          assert_equal [@war.id, @clash.id].sort, order.last(2)
        end

        test "books on the same number of lists are taken in id order, ranked ones first" do
          list_book(@got, lists(:basic_list))
          list_book(@crime, lists(:basic_list))
          rank(@clash, 1)
          order = record_applies

          run_backfill

          assert_equal [@clash.id, *[@crime.id, @got.id].sort, @war.id], order
        end

        test "with no limit every book in scope is done once" do
          order = record_applies

          run_backfill

          assert_equal [@war, @crime, @got, @clash].map(&:id).sort, order.sort
        end

        test "books already logged are skipped, except failed ones" do
          ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :confirmed, run_id: "old")
          ::Books::OpenLibraryBackfill.create!(book: @got, outcome: :reverted, run_id: "old")
          ::Books::OpenLibraryBackfill.create!(book: @clash, outcome: :unsure, run_id: "old")
          failed = ::Books::OpenLibraryBackfill.create!(book: @crime, outcome: :failed, run_id: "old")
          order = []
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            failed.update!(outcome: :keyed, run_id: run_id)
            true
          end.returns(ApplyBook::Result.new(success?: true, data: nil, errors: []))

          run_backfill

          assert_equal [@crime.id], order
        end

        test "the same run started again counts the books it already did toward its limit" do
          ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :keyed, run_id: "run-1")
          order = record_applies

          result = run_backfill(limit: 2)

          assert_equal 1, order.size
          assert_equal 2, result.data[:processed]
        end

        test "an Open Library failure waits and tries the same book again" do
          error = ::Books::OpenLibrary::Exceptions::ServerError.new("busy", 500)
          tried = []
          ApplyBook.stubs(:call).with do |book:, **|
            tried << book.id
            true
          end.raises(error).then.returns(ok)
          waits = []

          result = run_backfill(limit: 1, sleeper: ->(seconds) { waits << seconds })

          assert_equal [Run::RETRY_DELAYS.first], waits
          assert_equal 2, tried.size
          assert_equal 1, tried.uniq.size
          assert_equal 1, result.data[:processed]
        end

        test "a book-specific error (ClientError) logs that book failed with no wait and the run moves on" do
          bad = ::Books::OpenLibrary::Exceptions::ClientError.new("bad isbn", 422)
          order = []
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            raise bad if book.id == @war.id

            ::Books::OpenLibraryBackfill.create!(book: book, outcome: :keyed, run_id: run_id)
            true
          end.returns(ok)

          result = run_backfill

          assert_equal [@war.id, @crime.id, @got.id, @clash.id].sort, order.sort
          assert_equal "failed", ::Books::OpenLibraryBackfill.find_by!(book: @war).outcome
          assert_equal false, result.data[:stopped]
          assert_equal 3, result.data[:processed]
        end

        test "a 403 is an outage: the run waits, retries and stops" do
          ApplyBook.stubs(:call).raises(::Books::OpenLibrary::Exceptions::ClientError.new("forbidden", 403))
          waits = []

          result = run_backfill(sleeper: ->(seconds) { waits << seconds })

          assert_equal Run::RETRY_DELAYS, waits
          assert_equal true, result.data[:stopped]
          assert_equal 1, ::Books::OpenLibraryBackfill.failed.count
        end

        test "a book that failed before is taken after books never tried" do
          rank(@war, 1)
          ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :failed, run_id: "old")
          order = record_applies

          run_backfill(limit: 1)

          assert_not_equal @war.id, order.first
          assert_equal 1, order.size
        end

        test "one call never takes the same book twice" do
          calls = []
          ApplyBook.stubs(:call).with do |book:, **|
            calls << book.id
            true
          end.returns(ApplyBook::Result.new(success?: false, data: nil, errors: []))

          run_backfill

          assert_equal [@war, @crime, @got, @clash].map(&:id).sort, calls.sort
        end

        test "a book that keeps failing is logged failed after the last wait, and the run stops" do
          ApplyBook.stubs(:call).raises(::Books::OpenLibrary::Exceptions::ServerError.new("down", 500))
          waits = []

          result = run_backfill(sleeper: ->(seconds) { waits << seconds })

          assert_equal Run::RETRY_DELAYS, waits
          assert_equal true, result.data[:stopped]
          assert_match(/down/, result.data[:error])
          assert_equal 1, ::Books::OpenLibraryBackfill.failed.count
        end

        test "retry_unsure takes unsure books from an older Open Library version only" do
          @client = FakeOlClient.new(version: {dump_date: "2026-09-30", matcher_version: 3})
          [@crime, @got, @clash].each { |book| ::Books::OpenLibraryBackfill.create!(book: book, outcome: :keyed, run_id: "old") }
          stale = ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :unsure, run_id: "old", dump_date: "2026-07-31", matcher_version: 3)
          order = []
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            stale.update!(dump_date: "2026-09-30", run_id: run_id)
            true
          end.returns(ApplyBook::Result.new(success?: true, data: nil, errors: []))

          run_backfill(retry_unsure: true)
          assert_equal [@war.id], order

          order.clear
          stale.update!(dump_date: "2026-09-30")
          run_backfill(retry_unsure: true)
          assert_empty order
        end

        test "retry_unsure also takes an unsure book from an older matcher on the same dump" do
          @client = FakeOlClient.new(version: {dump_date: "2026-09-30", matcher_version: 3})
          [@crime, @got, @clash].each { |book| ::Books::OpenLibraryBackfill.create!(book: book, outcome: :keyed, run_id: "old") }
          stale = ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :unsure, run_id: "old", dump_date: "2026-09-30", matcher_version: 2)
          order = []
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            stale.update!(matcher_version: 3, run_id: run_id)
            true
          end.returns(ok)

          run_backfill(retry_unsure: true)

          assert_equal [@war.id], order
        end

        test "a book settled through /resolve is followed by one RESOLVE_PAUSE wait; one settled by identifiers is not" do
          resolve_row = ::Books::OpenLibraryBackfill.new(lookup: :resolve)
          identifiers_row = ::Books::OpenLibraryBackfill.new(lookup: :identifiers)
          rank(@war, 1)
          rank(@crime, 2)
          ApplyBook.stubs(:call).with do |book:, run_id:, **|
            ::Books::OpenLibraryBackfill.create!(book: book, outcome: :keyed, run_id: run_id)
            true
          end.returns(ApplyBook::Result.new(success?: true, data: resolve_row, errors: []))
            .then.returns(ApplyBook::Result.new(success?: true, data: identifiers_row, errors: []))
            .then.returns(ok)
          waits = []

          run_backfill(limit: 3, sleeper: ->(seconds) { waits << seconds })

          assert_equal [Run::RESOLVE_PAUSE], waits
          assert_equal 4, Run::RESOLVE_PAUSE
        end

        test "a skipped book is not followed by a pause" do
          ApplyBook.stubs(:call).returns(ApplyBook::Result.new(success?: false, data: nil, errors: []))

          result = run_backfill(sleeper: ->(seconds) { flunk "waited #{seconds}" })

          assert_equal 0, result.data[:processed]
        end

        test "without retry_unsure an unsure book is never taken again" do
          ::Books::OpenLibraryBackfill.create!(book: @war, outcome: :unsure, run_id: "old", dump_date: "2000-01-01", matcher_version: 1)
          order = record_applies

          run_backfill

          assert_not_includes order, @war.id
        end

        test "a lost insert race does not count toward the limit, and the run moves on" do
          order = record_applies(success: false)

          result = run_backfill(limit: 2)

          assert_equal 4, order.size
          assert_equal 0, result.data[:processed]
        end
      end
    end
  end
end
