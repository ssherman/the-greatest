# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    module Steps
      class BookFactsTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:got)
          stub_workflow_dispatch
        end

        def call(options: {}, author_names: [])
          run = BookEnrichment.start(@book, initiated_by: "test", options: options, author_names: author_names)
          BookFacts.new.call(step: run.step(:book_facts), run: run, target: @book)
        end

        def enrich_result(value)
          stub(success?: value, errors: ["no facts"])
        end

        test "runs EnrichBook without forced research or extra names by default" do
          ::Services::Books::EnrichBook.expects(:call).with(book: @book, force_research: false, author_names: [], goodreads_page: nil).returns(enrich_result(true))

          result = call

          assert_equal [:succeeded, "done"], [result.kind, result.outcome]
        end

        test "force_research and author_names travel from the run's options" do
          ::Services::Books::EnrichBook.expects(:call).with(book: @book, force_research: true, author_names: ["Stephen King"], goodreads_page: nil).returns(enrich_result(true))

          call(options: {force_research: true}, author_names: ["Stephen King"])
        end

        test "passes the Goodreads page when the goodreads step matched" do
          page = books_goodreads_pages(:war_and_peace_page)
          run = BookEnrichment.start(@book, initiated_by: "test")
          run.step(:goodreads).update_columns(state: WorkflowStep.states[:succeeded], result: {"matched" => true, "page_id" => page.id, "progress" => {}})
          ::Services::Books::EnrichBook.expects(:call).with(book: @book, force_research: false, author_names: [], goodreads_page: page).returns(enrich_result(true))

          BookFacts.new.call(step: run.step(:book_facts), run: run, target: @book)
        end

        test "passes nil for a version-1 run with no goodreads step" do
          run = BookEnrichment.start(@book, initiated_by: "test")
          run.step(:goodreads).destroy!
          ::Services::Books::EnrichBook.expects(:call).with(book: @book, force_research: false, author_names: [], goodreads_page: nil).returns(enrich_result(true))

          BookFacts.new.call(step: run.step(:book_facts), run: run.reload, target: @book)
        end

        test "passes nil when goodreads succeeded without a match" do
          run = BookEnrichment.start(@book, initiated_by: "test")
          run.step(:goodreads).update_columns(state: WorkflowStep.states[:succeeded], result: {"matched" => false})
          ::Services::Books::EnrichBook.expects(:call).with(book: @book, force_research: false, author_names: [], goodreads_page: nil).returns(enrich_result(true))

          BookFacts.new.call(step: run.step(:book_facts), run: run, target: @book)
        end

        test "passes nil when the matched page row no longer exists" do
          run = BookEnrichment.start(@book, initiated_by: "test")
          run.step(:goodreads).update_columns(state: WorkflowStep.states[:succeeded], result: {"matched" => true, "page_id" => 0})
          ::Services::Books::EnrichBook.expects(:call).with(book: @book, force_research: false, author_names: [], goodreads_page: nil).returns(enrich_result(true))

          BookFacts.new.call(step: run.step(:book_facts), run: run, target: @book)
        end

        test "a failed run raises so the coordinator retries it" do
          ::Services::Books::EnrichBook.stubs(:call).returns(enrich_result(false))

          error = assert_raises(StandardError) { call }

          assert_equal "Enrichment failed for book #{@book.id}: no facts", error.message
        end
      end
    end
  end
end
