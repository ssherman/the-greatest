# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class RunTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @war = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @got = books_books(:got)
          @clash = books_books(:clash)
          @scope = ::Books::Book.where(id: [@war, @crime, @got, @clash].map(&:id))
          @client = FakeOlClient.new
          # Fixture ids are hashed, normally far above the reserved ceiling.
          Cohort.stubs(:post_import_range).returns(1...1) unless [@war, @crime, @got, @clash].all? { |book| Cohort.for(book.id) == :pre_import }
        end

        test "the fixture books are pre_import" do
          assert_equal [:pre_import] * 4, [@war, @crime, @got, @clash].map { |book| Cohort.for(book.id) }
        end

        def no_sleep = ->(_seconds) { flunk "no wait expected" }

        def ok = VerifyBook::Result.new(success?: true, data: nil, errors: [])

        # VerifyBook stand-in: records the order and writes the row a real one would.
        def record_applies(success: true)
          order = []
          VerifyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            row = ::Books::Verification.find_or_initialize_by(book: book)
            row.update!(work_outcome: :keyed, run_id: success ? run_id : "other-run", stage: :done)
            true
          end.returns(VerifyBook::Result.new(success?: success, data: nil, errors: []))
          order
        end

        def rank(book, position)
          ::RankedItem.create!(item: book, ranking_configuration: ranking_configurations(:books_global), rank: position, score: 100 - position)
        end

        def run_backfill(**options)
          # Unranked by default so the order tests see every fixture book; the ranked-only default is tested on its own.
          Run.call(limit: nil, run_id: "run-1", client: @client, wc_client: FakeWcClient.new, sleeper: no_sleep, scope: @scope, flags: %w[unranked], **options)
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
          VerifyBook.expects(:call).never
          result = nil
          with_lock_held_elsewhere { result = run_backfill }

          assert_not result.success?
          assert_equal({processed: 0, stopped: true, error: "another verification run is in progress"}, result.data)
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

        test "two runs in one query cache scope both reach the server, and the lock ends free" do
          record_applies
          ActiveRecord::Base.connection.cache do
            run_backfill(limit: 1)
            run_backfill(limit: 1)
          end

          assert_lock_free
        end

        test "the lock is released when the run raises" do
          # A book's own error is recorded; recording it failing too (the
          # database is down) is what still ends the run.
          VerifyBook.stubs(:call).raises(RuntimeError, "boom")
          ApplyBook.stubs(:record_failure).raises(ActiveRecord::RecordNotUnique, "boom")
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
          ::Books::Verification.create!(book: @war, work_outcome: :confirmed, run_id: "old", stage: :done)
          ::Books::Verification.create!(book: @got, work_outcome: :reverted, run_id: "old")
          ::Books::Verification.create!(book: @clash, work_outcome: :unsure, run_id: "old", stage: :done)
          failed = ::Books::Verification.create!(book: @crime, work_outcome: :failed, run_id: "old")
          order = []
          VerifyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            failed.update!(work_outcome: :keyed, run_id: run_id, stage: :done)
            true
          end.returns(VerifyBook::Result.new(success?: true, data: nil, errors: []))

          run_backfill

          assert_equal [@crime.id], order
        end

        test "the same run started again counts the books it already did toward its limit" do
          ::Books::Verification.create!(book: @war, work_outcome: :keyed, run_id: "run-1", stage: :done)
          order = record_applies

          result = run_backfill(limit: 2)

          assert_equal 1, order.size
          assert_equal 2, result.data[:processed]
        end

        test "a row the same run left mid-stage is resumed, and only finished rows count toward the limit" do
          ::Books::Verification.create!(book: @war, work_outcome: :keyed, run_id: "run-1", stage: :done)
          ::Books::Verification.create!(book: @crime, work_outcome: :keyed, run_id: "run-1", stage: :worldcat)
          @scope = ::Books::Book.where(id: [@war.id, @crime.id])
          order = record_applies

          result = run_backfill(limit: 2)

          assert_equal [@crime.id], order
          assert_equal 2, result.data[:processed]
        end

        test "an Open Library failure waits and tries the same book again" do
          error = ::Books::OpenLibrary::Exceptions::ServerError.new("busy", 500)
          tried = []
          VerifyBook.stubs(:call).with do |book:, **|
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
          VerifyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            raise bad if book.id == @war.id

            ::Books::Verification.find_or_initialize_by(book: book).update!(work_outcome: :keyed, run_id: run_id, stage: :done)
            true
          end.returns(ok)

          result = run_backfill

          assert_equal [@war.id, @crime.id, @got.id, @clash.id].sort, order.sort
          assert_equal "failed", ::Books::Verification.find_by!(book: @war).work_outcome
          assert_equal false, result.data[:stopped]
          assert_equal 3, result.data[:processed]
        end

        test "a 403 is an outage: the run waits, retries and stops" do
          VerifyBook.stubs(:call).raises(::Books::OpenLibrary::Exceptions::ClientError.new("forbidden", 403))
          waits = []

          result = run_backfill(sleeper: ->(seconds) { waits << seconds })

          assert_equal Run::RETRY_DELAYS, waits
          assert_equal true, result.data[:stopped]
          assert_equal 1, ::Books::Verification.failed.count
        end

        test "a book that failed before is taken after books never tried" do
          rank(@war, 1)
          ::Books::Verification.create!(book: @war, work_outcome: :failed, run_id: "old")
          order = record_applies

          run_backfill(limit: 1)

          assert_not_equal @war.id, order.first
          assert_equal 1, order.size
        end

        test "one call never takes the same book twice" do
          calls = []
          VerifyBook.stubs(:call).with do |book:, **|
            calls << book.id
            true
          end.returns(VerifyBook::Result.new(success?: false, data: nil, errors: []))

          run_backfill

          assert_equal [@war, @crime, @got, @clash].map(&:id).sort, calls.sort
        end

        test "a book that keeps failing is logged failed after the last wait, and the run stops" do
          VerifyBook.stubs(:call).raises(::Books::OpenLibrary::Exceptions::ServerError.new("down", 500))
          waits = []

          result = run_backfill(sleeper: ->(seconds) { waits << seconds })

          assert_equal Run::RETRY_DELAYS, waits
          assert_equal true, result.data[:stopped]
          assert_match(/down/, result.data[:error])
          assert_equal 1, ::Books::Verification.failed.count
        end

        test "retry_unsure takes unsure books from an older Open Library version only" do
          @client = FakeOlClient.new(version: {dump_date: "2026-09-30", matcher_version: 3})
          [@crime, @got, @clash].each { |book| ::Books::Verification.create!(book: book, work_outcome: :keyed, run_id: "old", stage: :done) }
          stale = ::Books::Verification.create!(book: @war, work_outcome: :unsure, run_id: "old", stage: :done, dump_date: "2026-07-31", matcher_version: 3)
          order = []
          VerifyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            stale.reload.update!(dump_date: "2026-09-30", run_id: run_id, stage: :done)
            true
          end.returns(VerifyBook::Result.new(success?: true, data: nil, errors: []))

          run_backfill(flags: %w[retry_unsure unranked])
          assert_equal [@war.id], order

          order.clear
          stale.reload.update!(dump_date: "2026-09-30")
          run_backfill(flags: %w[retry_unsure unranked])
          assert_empty order
        end

        test "retry_unsure also takes an unsure book from an older matcher on the same dump" do
          @client = FakeOlClient.new(version: {dump_date: "2026-09-30", matcher_version: 3})
          [@crime, @got, @clash].each { |book| ::Books::Verification.create!(book: book, work_outcome: :keyed, run_id: "old", stage: :done) }
          stale = ::Books::Verification.create!(book: @war, work_outcome: :unsure, run_id: "old", stage: :done, dump_date: "2026-09-30", matcher_version: 2)
          order = []
          VerifyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            stale.reload.update!(matcher_version: 3, run_id: run_id, stage: :done)
            true
          end.returns(ok)

          run_backfill(flags: %w[retry_unsure unranked])

          assert_equal [@war.id], order
        end

        test "a book settled through /resolve is followed by one RESOLVE_PAUSE wait; one settled by identifiers is not" do
          resolve_row = VerifyBook::Outcome.new(row: nil, via_resolve: true)
          identifiers_row = VerifyBook::Outcome.new(row: nil, via_resolve: false)
          rank(@war, 1)
          rank(@crime, 2)
          VerifyBook.stubs(:call).with do |book:, run_id:, **|
            ::Books::Verification.find_or_initialize_by(book: book).update!(work_outcome: :keyed, run_id: run_id, stage: :done)
            true
          end.returns(VerifyBook::Result.new(success?: true, data: resolve_row, errors: []))
            .then.returns(VerifyBook::Result.new(success?: true, data: identifiers_row, errors: []))
            .then.returns(ok)
          waits = []

          run_backfill(limit: 3, sleeper: ->(seconds) { waits << seconds })

          assert_equal [Run::RESOLVE_PAUSE], waits
          assert_equal 4, Run::RESOLVE_PAUSE
        end

        test "a skipped book is not followed by a pause" do
          VerifyBook.stubs(:call).returns(VerifyBook::Result.new(success?: false, data: nil, errors: []))

          result = run_backfill(sleeper: ->(seconds) { flunk "waited #{seconds}" })

          assert_equal 0, result.data[:processed]
        end

        test "without retry_unsure an unsure book is never taken again" do
          ::Books::Verification.create!(book: @war, work_outcome: :unsure, run_id: "old", stage: :done, dump_date: "2000-01-01", matcher_version: 1)
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

        test "by default only ranked pre_import books are taken" do
          order = record_applies
          rank(@war, 1)
          rank(@crime, 2)
          Cohort.stubs(:post_import_range).returns(@crime.id..@crime.id)

          run_backfill(scope: nil, flags: [])

          assert_includes order, @war.id
          refute_includes order, @crime.id
          refute_includes order, @got.id
        end

        test "unranked continues past the ranking; post_import includes that cohort" do
          order = record_applies
          rank(@war, 1)
          Cohort.stubs(:post_import_range).returns(@crime.id..@crime.id)

          run_backfill(scope: nil, flags: %w[unranked post_import])

          assert_includes order, @crime.id
          assert_includes order, @got.id
        end

        test "a row stopped at a later stage is taken again; a done row is not" do
          order = record_applies
          ::Books::Verification.create!(book: @war, work_outcome: :keyed, run_id: "old", stage: :worldcat)
          ::Books::Verification.create!(book: @crime, work_outcome: :keyed, run_id: "old", stage: :done)

          run_backfill

          assert_includes order, @war.id
          refute_includes order, @crime.id
        end

        test "recheck takes done books that gained a legacy identifier since checked_at, from stage 2 or 3" do
          VerifyBook.stubs(:call).returns(VerifyBook::Result.new(success?: true, data: VerifyBook::Outcome.new(row: nil, via_resolve: false), errors: []))
          settled = ::Books::Verification.create!(book: @war, work_outcome: :keyed, run_id: "old", stage: :done, checked_at: 1.day.ago)
          unsure = ::Books::Verification.create!(book: @crime, work_outcome: :unsure, run_id: "old", stage: :done, checked_at: 1.day.ago)
          quiet = ::Books::Verification.create!(book: @got, work_outcome: :keyed, run_id: "old", stage: :done, checked_at: 1.minute.from_now)
          [@war, @crime, @got].each { |book| Identifier.create!(identifiable: book, identifier_type: :books_work_isbn10, value: "0140447938", source: :legacy) }

          run_backfill(flags: %w[recheck unranked])

          assert settled.reload.stage_identifiers?
          assert unsure.reload.stage_worldcat?
          assert quiet.reload.stage_done?
        end

        test "reharvest takes done books with a settled work and an Open Library duplicate work, from stage 2" do
          VerifyBook.stubs(:call).returns(VerifyBook::Result.new(success?: true, data: VerifyBook::Outcome.new(row: nil, via_resolve: false), errors: []))
          settled = ::Books::Verification.create!(book: @war, work_outcome: :replaced, run_id: "old", stage: :done)
          no_duplicate = ::Books::Verification.create!(book: @crime, work_outcome: :keyed, run_id: "old", stage: :done)
          unsure = ::Books::Verification.create!(book: @got, work_outcome: :unsure, run_id: "old", stage: :done)
          legacy_duplicate = ::Books::Verification.create!(book: @clash, work_outcome: :keyed, run_id: "old", stage: :done)
          [@war, @got].each { |book| Identifier.create!(identifiable: book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL9W", source: :open_library) }
          Identifier.create!(identifiable: @clash, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL9W", source: :legacy)

          run_backfill(flags: %w[reharvest unranked])

          assert settled.reload.stage_identifiers?
          assert [no_duplicate, unsure, legacy_duplicate].map(&:reload).all?(&:stage_done?)
        end

        test "reharvest does not take a book this run already finished, so a re-queued run does not redo it" do
          ::Books::Verification.create!(book: @war, work_outcome: :keyed, run_id: "run-1", stage: :done)
          Identifier.create!(identifiable: @war, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL9W", source: :open_library)
          VerifyBook.expects(:call).never

          run_backfill(flags: %w[reharvest unranked], scope: ::Books::Book.where(id: @war.id))
        end

        test "a WorldCat outage after the retries stops the run and leaves the book at its stage" do
          ::Books::Verification.create!(book: @war, work_outcome: :keyed, new_key: "OL1W", run_id: "old", stage: :worldcat)
          VerifyBook.stubs(:call).raises(::Books::WorldCat::Exceptions::ServerError.new("down", 503))
          sleeps = []

          result = Run.call(limit: nil, run_id: "run-1", client: @client, wc_client: FakeWcClient.new, sleeper: ->(s) { sleeps << s },
            scope: ::Books::Book.where(id: @war.id), flags: %w[unranked])

          assert result.data[:stopped]
          assert_equal Run::RETRY_DELAYS, sleeps
          row = ::Books::Verification.find_by!(book: @war)
          assert row.stage_worldcat?
          assert_match(/ServerError/, row.stage_error)
        end

        test "an unknown flag is refused" do
          assert_raises(ArgumentError) { run_backfill(flags: %w[everything]) }
        end

        test "recheck never takes a reverted book, even one with a newer legacy identifier" do
          reverted = ::Books::Verification.create!(book: @war, work_outcome: :reverted, run_id: "old", stage: :done, checked_at: 1.day.ago)
          Identifier.create!(identifiable: @war, identifier_type: :books_work_isbn10, value: "0140447938", source: :legacy)
          VerifyBook.expects(:call).never

          run_backfill(flags: %w[recheck unranked], scope: ::Books::Book.where(id: @war.id))

          assert reverted.reload.stage_done?
        end

        test "a 404 at a later stage stops that book at its stage with no wait, and the run goes on" do
          row = ::Books::Verification.create!(book: @war, work_outcome: :keyed, new_key: "OL1W", run_id: "old", stage: :identifiers)
          order = []
          VerifyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            raise ::Books::OpenLibrary::Exceptions::NotFoundError.new("no such work", 404) if book.id == @war.id

            ::Books::Verification.find_or_initialize_by(book: book).update!(work_outcome: :keyed, run_id: run_id, stage: :done)
            true
          end.returns(ok)

          result = run_backfill

          assert_not result.data[:stopped]
          assert_equal [@war, @crime, @got, @clash].map(&:id).sort, order.sort
          assert row.reload.stage_identifiers?
          assert_match(/NotFoundError.*no such work/, row.stage_error)
        end

        test "an unexpected error on one book is recorded on its row and the run goes on" do
          row = ::Books::Verification.create!(book: @war, work_outcome: :keyed, new_key: "OL1W", run_id: "old", stage: :signals)
          order = []
          VerifyBook.stubs(:call).with do |book:, run_id:, **|
            order << book.id
            raise URI::InvalidURIError, "bad URI (is not URI?): \"/identifiers/isbn13/Twelfth Night\"" if book.id == @war.id

            ::Books::Verification.find_or_initialize_by(book: book).update!(work_outcome: :keyed, run_id: run_id, stage: :done)
            true
          end.returns(ok)

          result = run_backfill

          assert_not result.data[:stopped]
          assert_equal [@war, @crime, @got, @clash].map(&:id).sort, order.sort
          assert row.reload.stage_signals?
          assert_match(/URI::InvalidURIError.*Twelfth Night/, row.stage_error)
        end

        test "unexpected errors on UNEXPECTED_ERROR_LIMIT books in a row stop the run with the last one" do
          VerifyBook.stubs(:call).raises(RuntimeError, "every book breaks")

          result = run_backfill

          assert result.data[:stopped]
          assert_match(/RuntimeError: every book breaks/, result.data[:error])
          assert_equal Run::UNEXPECTED_ERROR_LIMIT, ::Books::Verification.where(work_outcome: :failed).count
        end

        test "a WorldCat 404 is book-specific too" do
          ::Books::Verification.create!(book: @war, work_outcome: :keyed, run_id: "old", stage: :worldcat)
          VerifyBook.stubs(:call).raises(::Books::WorldCat::Exceptions::NotFoundError.new("gone", 404))

          result = run_backfill(scope: ::Books::Book.where(id: @war.id))

          assert_not result.data[:stopped]
        end
      end
    end
  end
end
