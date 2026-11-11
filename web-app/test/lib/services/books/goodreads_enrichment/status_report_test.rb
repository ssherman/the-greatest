# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class StatusReportTest < ActiveSupport::TestCase
        NOW = Time.utc(2026, 11, 10, 5)

        setup do
          travel_to NOW
          @gate = ::Books::Goodreads::FetchGate.new(redis: ::Books::OpenLibrary::FakeRedis.new)
        end

        def goodreads_step(book, state:, outcome: nil, error: nil, finished_at: nil)
          run = WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 1, enrichable: book,
            initiated_by: "test", options: {}, status: :completed)
          WorkflowStep.create!(run: run, key: "goodreads", queue: "goodreads_fetch", lease_seconds: 600, state: state,
            outcome: outcome, error: error, finished_at: finished_at)
        end

        def report = StatusReport.call(gate: @gate).data[:report]

        test "an open gate shows the day's reservations against the cap" do
          3.times { @gate.reserve }

          assert_match(/Fetch gate: open\n  2026-11-10: 3 of 1500 fetches reserved/, report)
        end

        test "a blocked gate says until when" do
          @gate.block!

          assert_match(/Fetch gate: BLOCKED until 2026-11-10 11:00 UTC/, report)
        end

        test "counts the last day's stored pages and searches by outcome, and leaves older ones out" do
          ::Books::GoodreadsPage.create!(goodreads_book_id: 1, outcome: :found, fetched_at: 1.hour.ago)
          ::Books::GoodreadsPage.create!(goodreads_book_id: 2, outcome: :found, fetched_at: 2.hours.ago)
          ::Books::GoodreadsPage.create!(goodreads_book_id: 3, outcome: :not_found, fetched_at: 3.hours.ago)
          ::Books::GoodreadsPage.create!(goodreads_book_id: 4, outcome: :found, fetched_at: 2.days.ago)
          ::Books::GoodreadsSearch.create!(query: "babylon", outcome: :unparseable, fetched_at: 10.minutes.ago)

          text = report
          assert_match(/book pages: found 2, not_found 1\n/, text)
          assert_match(/searches:   unparseable 1\n/, text)
          assert_match(/last stored fetch: 2026-11-10 04:50 UTC \(10 minutes ago\)/, text)
        end

        test "with nothing stored it says so" do
          ::Books::GoodreadsPage.delete_all
          ::Books::GoodreadsSearch.delete_all

          text = report
          assert_match(/book pages: none\n/, text)
          assert_match(/last stored fetch: never/, text)
        end

        test "shows open steps, the last day's outcomes and failures by cause, and the all-time failure count" do
          goodreads_step(books_books(:war_and_peace), state: :waiting)
          goodreads_step(books_books(:crime_and_punishment), state: :succeeded, outcome: "matched", finished_at: 1.hour.ago)
          goodreads_step(books_books(:got), state: :failed, finished_at: 2.hours.ago,
            error: "StandardError: Goodreads fetch for book 1 failed: unavailable")
          goodreads_step(books_books(:clash), state: :failed, finished_at: 5.days.ago,
            error: "StandardError: Goodreads fetch for book 2 failed: fetcher_down")

          text = report
          assert_match(/open now: waiting 1\n/, text)
          assert_match(/succeeded in the last 24 hours: matched 1\n/, text)
          assert_match(/failed in the last 24 hours \(attempts used up\): unavailable 1\n/, text)
          assert_match(/failed, all time: 2\z/, text)
        end
      end
    end
  end
end
