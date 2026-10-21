# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    class AdoptDeferredTest < ActiveSupport::TestCase
      setup do
        # got is linked to king; garnett is linked below.
        @book = books_books(:got)
        @author = books_authors(:king)
        @other_author = books_authors(:garnett)
        ::Books::BookAuthor.create!(book: @book, author: @other_author, position: 2, role: :author)
        # The fixture run on Tolstoy has only a wikidata step, which no real run
        # does; war_and_peace is his book, so end it rather than wait on it.
        Workflows::Coordinator.cancel(workflow_runs(:tolstoy_author_run), outcome: "test")
        stub_workflow_dispatch
      end

      def book_runs(*books)
        WorkflowRun.where(workflow: "books.book_enrichment", enrichable: books)
      end

      def prerequisites_of(step)
        step.dependencies.map(&:prerequisite_step_id)
      end

      test "plans a book_facts-only run for a deferred book, waiting on its author's active run" do
        ::Services::Books::DeferredEnrichment.defer!(@book)
        author_run = AuthorEnrichment.start(@author, initiated_by: "test")

        result = AdoptDeferred.call

        run = book_runs(@book).sole
        assert_equal [{planned: 1, skipped_active: 0}, "adopt_deferred", "not_requested", [author_run.step(:author_facts).id]], [
          result, run.initiated_by, run.step(:amazon).outcome, prerequisites_of(run.step(:book_facts))
        ]
      end

      test "does not start an author run for a linked author that has none" do
        ::Services::Books::DeferredEnrichment.defer!(@book)
        author_run = AuthorEnrichment.start(@author, initiated_by: "test")

        AdoptDeferred.call

        assert_equal [author_run.id],
          WorkflowRun.where(workflow: "books.author_enrichment", enrichable: [@author, @other_author]).pluck(:id)
      end

      test "a deferred book whose authors have no active run gets a book_facts that is ready at once" do
        ::Services::Books::DeferredEnrichment.defer!(@book)

        AdoptDeferred.call

        step = book_runs(@book).sole.step(:book_facts)
        assert_equal ["ready", []], [step.state, prerequisites_of(step)]
      end

      test "leaves alone a book whose latest book_facts row is not the deferral, and one never deferred" do
        ::Services::Books::DeferredEnrichment.defer!(@book)
        @book.enrichments.create!(kind: "books.book_facts", outcome: :applied)
        never_deferred = books_books(:war_and_peace)

        result = AdoptDeferred.call

        assert_equal [{planned: 0, skipped_active: 0}, 0], [result, book_runs(@book, never_deferred).count]
      end

      test "counts a deferred book that already has a running book run, and leaves that run alone" do
        ::Services::Books::DeferredEnrichment.defer!(@book)
        existing = BookEnrichment.start(@book, initiated_by: "import")

        result = AdoptDeferred.call

        assert_equal [{planned: 0, skipped_active: 1}, [existing.id]], [result, book_runs(@book).pluck(:id)]
      end

      test "is idempotent: a second call plans nothing new" do
        ::Services::Books::DeferredEnrichment.defer!(@book)

        first = AdoptDeferred.call
        second = AdoptDeferred.call

        assert_equal [{planned: 1, skipped_active: 0}, {planned: 0, skipped_active: 1}, 1],
          [first, second, book_runs(@book).count]
      end

      test "a limit caps the books planned, lowest id first, and the next call takes the rest" do
        other_book = books_books(:war_and_peace)
        [@book, other_book].each { |book| ::Services::Books::DeferredEnrichment.defer!(book) }
        first_id, last_id = [@book, other_book].map(&:id).minmax

        first = AdoptDeferred.call(limit: 1)
        planned_after_first = book_runs(@book, other_book).pluck(:enrichable_id)
        second = AdoptDeferred.call(limit: 1)

        assert_equal [{planned: 1, skipped_active: 0}, [first_id], {planned: 1, skipped_active: 1}, [first_id, last_id]],
          [first, planned_after_first, second, book_runs(@book, other_book).order(:enrichable_id).pluck(:enrichable_id)]
      end
    end
  end
end
