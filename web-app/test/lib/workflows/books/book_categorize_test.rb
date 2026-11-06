# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    class BookCategorizeTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:got)
        stub_workflow_dispatch
      end

      test "is registered as books.book_categorize version 1 on books" do
        assert_equal [BookCategorize, "books.book_categorize", 1, ::Books::Book], [
          Workflows::Registry.fetch("books.book_categorize"), BookCategorize.workflow, BookCategorize.version, BookCategorize.target_class
        ]
        assert_equal %i[evidence categorize], BookCategorize.steps.map(&:key)
        assert_equal [{}, {evidence: :finish}], BookCategorize.steps.map(&:waits_on)
        assert_equal [:evidence, :low], BookCategorize.steps.map(&:queue)
      end

      test "plans evidence then categorize, and a second start reuses the active run" do
        run = BookCategorize.start(@book, initiated_by: "backfill", options: {"context" => "backfill"})

        assert_equal %w[categorize evidence], run.steps.map(&:key).sort
        assert_equal ["ready", "blocked"], [run.step(:evidence).state, run.step(:categorize).state]
        assert_equal run, BookCategorize.start(@book, initiated_by: "backfill")
      end

      test "start_after holds the evidence step" do
        run = BookCategorize.start(@book, initiated_by: "backfill", start_after: 1.hour.from_now)

        assert run.step(:evidence).waiting?
      end
    end
  end
end
