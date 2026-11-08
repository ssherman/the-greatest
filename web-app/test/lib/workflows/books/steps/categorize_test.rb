# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    module Steps
      class CategorizeTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:got)
          stub_workflow_dispatch
        end

        def ok_result(reason: "shortcut")
          row = stub(id: 7, reason: reason, outcome: "applied")
          ::Services::Books::Origin::Judge::Result.new(success?: true, data: {enrichments: [row], applied: true}, errors: [])
        end

        def failed_result
          ::Services::Books::Origin::Judge::Result.new(success?: false, data: {enrichments: []}, errors: ["boom"])
        end

        def import_run(options = {}, initiated_by: "importer")
          BookEnrichment.start(@book, initiated_by: initiated_by, options: options)
        end

        def categorize_run(options = {})
          BookCategorize.start(@book, initiated_by: "test", options: options)
        end

        def call(run)
          Categorize.new.call(step: run.step(:categorize), run: run, target: @book)
        end

        test "calls the judge with import context in a book_enrichment run" do
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(context: "import", research_allowed: true, force: false, force_research: false)).returns(ok_result)

          call(import_run)
        end

        test "a bulk re-run initiator gets the backfill context" do
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(context: "backfill")).returns(ok_result)

          call(import_run({}, initiated_by: "goodreads_rebuild"))
        end

        test "goodreads_promote is an import" do
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(context: "import")).returns(ok_result)

          call(import_run({}, initiated_by: "goodreads_promote"))
        end

        test "an explicit context option wins over the initiator" do
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(context: "admin")).returns(ok_result)

          call(import_run({"context" => "admin"}, initiated_by: "goodreads_rebuild"))
        end

        test "no research when the run's options say the book was already researched" do
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(research_allowed: false)).returns(ok_result)

          call(categorize_run("book_facts_researched" => true))
        end

        test "no research when book_facts researched in this run" do
          run = import_run
          @book.enrichments.create!(kind: "books.book_facts", mode: :research, outcome: :applied, workflow_step_id: run.step(:book_facts).id)
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(research_allowed: false)).returns(ok_result)

          call(run)
        end

        test "research stays allowed when book_facts did not research in this run" do
          run = import_run
          @book.enrichments.create!(kind: "books.book_facts", mode: :research, outcome: :applied)
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(research_allowed: true)).returns(ok_result)

          call(run)
        end

        test "force_research in a book_enrichment run belongs to book_facts, not the judge" do
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(force_research: false)).returns(ok_result)

          call(import_run({"force_research" => true}))
        end

        test "backfill context and label come from a book_categorize run, which allows research and passes force options" do
          run = categorize_run("context" => "backfill", "label" => "origin-v1", "force_judge" => true, "force_research" => true)
          ::Services::Books::Origin::Judge.expects(:call)
            .with(has_entries(context: "backfill", label: "origin-v1", research_allowed: true, force: true, force_research: true)).returns(ok_result)

          call(run)
        end

        test "a book_categorize run defaults to the backfill context" do
          ::Services::Books::Origin::Judge.expects(:call).with(has_entries(context: "backfill")).returns(ok_result)

          call(categorize_run)
        end

        test "succeeds with the last row's reason and the row ids" do
          ::Services::Books::Origin::Judge.stubs(:call).returns(ok_result(reason: "judged"))

          result = call(import_run)

          assert_equal [:succeeded, "judged", {"enrichment_ids" => [7], "applied" => true}], [result.kind, result.outcome, result.result]
        end

        test "falls back to the outcome when the reason is blank" do
          ::Services::Books::Origin::Judge.stubs(:call).returns(ok_result(reason: nil))

          assert_equal "applied", call(import_run).outcome
        end

        test "a failed judge raises so the coordinator retries" do
          ::Services::Books::Origin::Judge.stubs(:call).returns(failed_result)

          assert_raises(StandardError) { call(import_run) }
        end
      end
    end
  end
end
