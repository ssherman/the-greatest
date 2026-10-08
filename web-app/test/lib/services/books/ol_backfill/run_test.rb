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

        test "ranked books come first, by rank, and the run stops after its limit" do
          rank(@got, 2)
          rank(@clash, 1)
          order = record_applies

          result = run_backfill(limit: 2)

          assert_equal [@clash.id, @got.id], order
          assert_equal({processed: 2, stopped: false, error: nil}, result.data)
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
