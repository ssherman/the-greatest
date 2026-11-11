# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    module Steps
      class CategoriesTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:got)
          stub_workflow_dispatch
        end

        def ok_result(reason: "applied_rules")
          row = stub(id: 9, reason: reason, outcome: "applied")
          ::Services::Books::Categories::Judge::Result.new(success?: true, data: {enrichments: [row], applied: true}, errors: [])
        end

        def failed_result
          ::Services::Books::Categories::Judge::Result.new(success?: false, data: {enrichments: []}, errors: ["boom"])
        end

        def import_run(options = {}, initiated_by: "importer")
          BookEnrichment.start(@book, initiated_by: initiated_by, options: options)
        end

        def categorize_run(options = {})
          BookCategorize.start(@book, initiated_by: "test", options: options)
        end

        def call(run)
          Categories.new.call(step: run.step(:categories), run: run, target: @book)
        end

        test "calls the judge with import context, research allowed and no force in an import" do
          ::Services::Books::Categories::Judge.expects(:call)
            .with(book: @book, context: "import", label: nil, research_allowed: true, force_research: false).returns(ok_result)

          call(import_run)
        end

        test "a bulk re-run initiator gets the backfill context" do
          ::Services::Books::Categories::Judge.expects(:call).with(has_entries(context: "backfill")).returns(ok_result)

          call(import_run({}, initiated_by: "goodreads_rebuild"))
        end

        test "no research when the run's options say the book was already researched" do
          ::Services::Books::Categories::Judge.expects(:call).with(has_entries(research_allowed: false)).returns(ok_result)

          call(categorize_run("book_facts_researched" => true))
        end

        test "no research when book_facts researched in this run" do
          run = import_run
          @book.enrichments.create!(kind: "books.book_facts", mode: :research, outcome: :applied, workflow_step_id: run.step(:book_facts).id)
          ::Services::Books::Categories::Judge.expects(:call).with(has_entries(research_allowed: false)).returns(ok_result)

          call(run)
        end

        test "no research when categorize researched in this run" do
          run = import_run
          @book.enrichments.create!(kind: "books.origin", mode: :research, outcome: :applied, workflow_step_id: run.step(:categorize).id)
          ::Services::Books::Categories::Judge.expects(:call).with(has_entries(research_allowed: false)).returns(ok_result)

          call(run)
        end

        test "a skipped research-mode row from book_facts does not count" do
          run = import_run
          @book.enrichments.create!(kind: "books.book_facts", mode: :research, outcome: :skipped, workflow_step_id: run.step(:book_facts).id)
          ::Services::Books::Categories::Judge.expects(:call).with(has_entries(research_allowed: true)).returns(ok_result)

          call(run)
        end

        test "research stays allowed when only another run's step researched" do
          run = import_run
          @book.enrichments.create!(kind: "books.origin", mode: :research, outcome: :applied)
          ::Services::Books::Categories::Judge.expects(:call).with(has_entries(research_allowed: true)).returns(ok_result)

          call(run)
        end

        test "force_research in a book_enrichment run belongs to book_facts, not the judge" do
          ::Services::Books::Categories::Judge.expects(:call).with(has_entries(force_research: false)).returns(ok_result)

          call(import_run({"force_research" => true}))
        end

        test "a book_categorize run passes context, label and force_research" do
          run = categorize_run("context" => "backfill", "label" => "cat-v1", "force_research" => true)
          ::Services::Books::Categories::Judge.expects(:call)
            .with(has_entries(context: "backfill", label: "cat-v1", research_allowed: true, force_research: true)).returns(ok_result)

          call(run)
        end

        test "succeeds with the last row's reason and the row ids" do
          ::Services::Books::Categories::Judge.stubs(:call).returns(ok_result(reason: "judged"))

          result = call(import_run)

          assert_equal [:succeeded, "judged", {"enrichment_ids" => [9], "applied" => true}], [result.kind, result.outcome, result.result]
        end

        test "a failed judge raises so the coordinator retries" do
          ::Services::Books::Categories::Judge.stubs(:call).returns(failed_result)

          assert_raises(StandardError) { call(import_run) }
        end
      end
    end
  end
end
