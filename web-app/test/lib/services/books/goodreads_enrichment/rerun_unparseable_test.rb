# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class RerunUnparseableTest < ActiveSupport::TestCase
        WORKFLOW = "books.book_enrichment"
        BOOK_ENRICHMENT = ::Workflows::Books::BookEnrichment

        def book(title)
          ::Books::Book.create!(title: title).tap { |b| b.authors << ::Books::Author.create!(name: "Joseph Heller") }
        end

        # A finished book run whose goodreads step ended with this outcome.
        def finished_run(book, outcome:, status: :completed, created_at: 2.days.ago, author_names: ["Joseph Heller"], options: {})
          run = WorkflowRun.create!(workflow: WORKFLOW, definition_version: 2, enrichable: book, initiated_by: "goodreads_rebuild",
            options: options.merge("author_names" => author_names), status: status, created_at: created_at)
          run.steps.create!(key: "goodreads", queue: "goodreads_fetch", lease_seconds: 600, state: :succeeded,
            outcome: outcome, result: {})
          run
        end

        test "starts a new book run for each book whose latest goodreads step was unparseable, with its options" do
          catch22 = book("Catch-22")
          finished_run(catch22, outcome: "unparseable", author_names: ["Joseph Heller"], options: {"force_research" => true})
          matched = book("Closing Time")
          finished_run(matched, outcome: "matched")
          started = []
          BOOK_ENRICHMENT.expects(:start).with { |b, **kw| started << [b, kw] }.returns(stub)

          result = RerunUnparseable.call(limit: 10)

          assert_equal [[catch22, {initiated_by: "goodreads_unparseable_rerun", author_names: ["Joseph Heller"],
                                   options: {"force_research" => true}}]], started
          assert_equal({started: 1, remaining: 0}, result.data)
        end

        test "a book whose newer run did not end unparseable is not run again" do
          b = book("Catch-22")
          finished_run(b, outcome: "unparseable", created_at: 3.days.ago)
          finished_run(b, outcome: "matched", created_at: 1.day.ago)
          BOOK_ENRICHMENT.expects(:start).never

          assert_equal 0, RerunUnparseable.call(limit: 10).data[:started]
        end

        test "a book with a run still going is left to it" do
          b = book("Catch-22")
          finished_run(b, outcome: "unparseable", status: :running)
          BOOK_ENRICHMENT.expects(:start).never

          assert_equal 0, RerunUnparseable.call(limit: 10).data[:started]
        end

        test "starts at most limit books, oldest miss first, and reports how many remain" do
          older = book("Catch-22")
          finished_run(older, outcome: "unparseable", created_at: 3.days.ago)
          newer = book("Closing Time")
          finished_run(newer, outcome: "unparseable", created_at: 1.day.ago)
          BOOK_ENRICHMENT.expects(:start).with { |b, **| b == older }.returns(stub)

          assert_equal({started: 1, remaining: 1}, RerunUnparseable.call(limit: 1).data)
        end

        test "a second call does not start the same book again" do
          b = book("Catch-22")
          finished_run(b, outcome: "unparseable")

          first, second = Sidekiq::Testing.fake! { [RerunUnparseable.call(limit: 10), RerunUnparseable.call(limit: 10)] }

          assert_equal [1, 0], [first.data[:started], second.data[:started]]
          assert_equal ["goodreads_unparseable_rerun"], WorkflowRun.running.where(enrichable: b).pluck(:initiated_by)
        end

        test "a book that was deleted is skipped" do
          b = book("Catch-22")
          finished_run(b, outcome: "unparseable")
          b.book_authors.delete_all
          b.delete
          BOOK_ENRICHMENT.expects(:start).never

          assert_equal 0, RerunUnparseable.call(limit: 10).data[:started]
        end
      end
    end
  end
end
