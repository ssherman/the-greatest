# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      # The selection rules RerunFailed shares with RerunUnparseable (latest run,
      # running runs, limit, order, deleted books) are tested there.
      class RerunFailedTest < ActiveSupport::TestCase
        WORKFLOW = "books.book_enrichment"
        BOOK_ENRICHMENT = ::Workflows::Books::BookEnrichment

        def book(title)
          ::Books::Book.create!(title: title).tap { |b| b.authors << ::Books::Author.create!(name: "Joseph Heller") }
        end

        def finished_run(book, state:, outcome: nil, created_at: 2.days.ago, options: {})
          run = WorkflowRun.create!(workflow: WORKFLOW, definition_version: 2, enrichable: book, initiated_by: "goodreads_rebuild",
            options: options.merge("author_names" => ["Joseph Heller"]), status: :completed_with_failures, created_at: created_at)
          run.steps.create!(key: "goodreads", queue: "goodreads_fetch", lease_seconds: 600, state: state, outcome: outcome,
            error: (state == :failed) ? "StandardError: Goodreads fetch for book #{book.id} failed: unavailable" : nil, result: {})
          run
        end

        test "starts a new book run for each book whose latest goodreads step failed, with its options" do
          failed = book("Catch-22")
          finished_run(failed, state: :failed, options: {"force_research" => true})
          unparseable = book("Closing Time")
          finished_run(unparseable, state: :succeeded, outcome: "unparseable")
          started = []
          BOOK_ENRICHMENT.expects(:start).with { |b, **kw| started << [b, kw] }.returns(stub)

          result = RerunFailed.call(limit: 10)

          assert_equal [[failed, {initiated_by: "goodreads_failed_rerun", author_names: ["Joseph Heller"],
                                  options: {"force_research" => true}}]], started
          assert_equal({started: 1, remaining: 0}, result.data)
        end

        test "a book whose newer run's goodreads step did not fail is not run again" do
          b = book("Catch-22")
          finished_run(b, state: :failed, created_at: 3.days.ago)
          finished_run(b, state: :succeeded, outcome: "matched", created_at: 1.day.ago)
          BOOK_ENRICHMENT.expects(:start).never

          assert_equal 0, RerunFailed.call(limit: 10).data[:started]
        end

        test "a second call does not start the same book again" do
          b = book("Catch-22")
          finished_run(b, state: :failed)

          first, second = Sidekiq::Testing.fake! { [RerunFailed.call(limit: 10), RerunFailed.call(limit: 10)] }

          assert_equal [1, 0], [first.data[:started], second.data[:started]]
          assert_equal ["goodreads_failed_rerun"], WorkflowRun.running.where(enrichable: b).pluck(:initiated_by)
        end
      end
    end
  end
end
