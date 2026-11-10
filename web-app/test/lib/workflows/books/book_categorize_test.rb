# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    class BookCategorizeTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:got)
        stub_workflow_dispatch
      end

      test "is registered as books.book_categorize version 2 on books" do
        assert_equal [BookCategorize, "books.book_categorize", 2, ::Books::Book], [
          Workflows::Registry.fetch("books.book_categorize"), BookCategorize.workflow, BookCategorize.version, BookCategorize.target_class
        ]
        assert_equal %i[evidence categorize categories], BookCategorize.steps.map(&:key)
        assert_equal [{}, {evidence: :finish}, {categorize: :finish, evidence: :finish}], BookCategorize.steps.map(&:waits_on)
        assert_equal [:evidence, :low, :low], BookCategorize.steps.map(&:queue)
      end

      test "plans evidence then categorize, and a second start reuses the active run" do
        run = BookCategorize.start(@book, initiated_by: "backfill", options: {"context" => "backfill"})

        assert_equal %w[categories categorize evidence], run.steps.map(&:key).sort
        assert_equal ["ready", "blocked"], [run.step(:evidence).state, run.step(:categorize).state]
        assert_equal run, BookCategorize.start(@book, initiated_by: "backfill")
      end

      test "no scope plans every step" do
        run = BookCategorize.start(@book, initiated_by: "backfill")

        assert_equal %w[blocked blocked ready], %w[categorize categories evidence].map { run.step(it).state }
      end

      test "scope all plans every step" do
        run = BookCategorize.start(@book, initiated_by: "backfill", options: {"scope" => "all"})

        assert_equal %w[blocked blocked ready], %w[categorize categories evidence].map { run.step(it).state }
      end

      test "scope categories_only plans categorize skipped and categories ready once evidence finishes" do
        run = BookCategorize.start(@book, initiated_by: "test", options: {"scope" => "categories_only"})

        assert_equal ["skipped", "scope_categories_only", "ready", "blocked"],
          [run.step(:categorize).state, run.step(:categorize).outcome, run.step(:evidence).state, run.step(:categories).state]
        claimed = Workflows::Coordinator.claim(run.step(:evidence).id, token: "ev")
        Workflows::Coordinator.finish(claimed, token: "ev", outcome: Workflows::Outcome.succeeded("done", {}))
        assert_equal "ready", run.step(:categories).reload.state
      end

      test "scope origin_only plans categories skipped" do
        run = BookCategorize.start(@book, initiated_by: "test", options: {"scope" => "origin_only"})

        assert_equal ["skipped", "scope_origin_only", "blocked"], [run.step(:categories).state, run.step(:categories).outcome, run.step(:categorize).state]
      end

      test "an unknown scope raises" do
        assert_raises(ArgumentError) { BookCategorize.start(@book, initiated_by: "test", options: {"scope" => "nope"}) }
      end

      test "start_after holds the evidence step" do
        run = BookCategorize.start(@book, initiated_by: "backfill", start_after: 1.hour.from_now)

        assert run.step(:evidence).waiting?
      end
    end
  end
end
