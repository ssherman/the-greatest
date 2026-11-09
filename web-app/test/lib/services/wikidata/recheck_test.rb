# frozen_string_literal: true

require "test_helper"

module Services
  module Wikidata
    class RecheckTest < ActiveSupport::TestCase
      KIND = ::Services::Books::Evidence::Gather::KIND

      setup do
        stub_workflow_dispatch
        Enrichment.where(kind: KIND).delete_all
        ::Books::Book.update_all(created_at: 1.year.ago)
        ::Books::Author.update_all(created_at: 1.year.ago)
        @book = books_books(:got)
        @book.update_columns(created_at: 1.day.ago)
        @author = books_authors(:king)
        @author.update_columns(created_at: 1.day.ago)
        ::Identifier.where(identifiable: @author, identifier_type: :books_author_wikidata_qid).delete_all
      end

      def evidence(book, facts)
        book.enrichments.create!(kind: KIND, outcome: :nothing_to_apply, facts: facts)
      end

      def run_for(book) = WorkflowRun.where(enrichable: book, workflow: ::Workflows::Books::BookCategorize.workflow)

      test "a recent book with an unmatched, complete evidence row starts a regathering run" do
        evidence(@book, {"wikidata_qid" => nil, "sources_failed" => []})

        result = Recheck.call(dump_date: "2026-11-01", apply: true)

        run = run_for(@book).first
        assert_equal [1, "wikidata_recheck", {"context" => "backfill", "label" => "wikidata-2026-11-01", "regather" => true}],
          [result.data[:books], run.initiated_by, run.options]
      end

      test "an old book, a matched one and one with failed sources are skipped" do
        matched, failed, old = ::Books::Book.where.not(id: @book.id).limit(3).to_a
        [matched, failed].each { |book| book.update_columns(created_at: 1.day.ago) }
        evidence(@book, {"wikidata_qid" => "Q1", "sources_failed" => []})
        evidence(matched, {"wikidata_qid" => "Q2", "sources_failed" => []})
        evidence(failed, {"wikidata_qid" => nil, "sources_failed" => ["worldcat"]})
        evidence(old, {"wikidata_qid" => nil, "sources_failed" => []})

        assert_equal 0, Recheck.call(dump_date: "d", apply: true).data[:books]
        assert_equal 0, WorkflowRun.where(workflow: ::Workflows::Books::BookCategorize.workflow).count
      end

      test "only the latest evidence row counts" do
        evidence(@book, {"wikidata_qid" => nil, "sources_failed" => []})
        evidence(@book, {"wikidata_qid" => "Q9", "sources_failed" => []})

        assert_equal 0, Recheck.call(dump_date: "d").data[:books]
      end

      def author_runs = WorkflowRun.where(workflow: ::Workflows::Books::AuthorEnrichment.workflow, initiated_by: "wikidata_recheck")

      test "starts a Wikidata-only refresh run for recent authors without a QID" do
        result = Recheck.call(dump_date: "d", apply: true)

        run = author_runs.find_by!(enrichable: @author)
        assert_equal [1, 1, "wikidata_recheck", {"refresh" => true, "allow_research" => false, "only" => ["wikidata"]}],
          [result.data[:authors], author_runs.count, run.initiated_by, run.options]
      end

      test "starts are spaced like the origin backfill" do
        second = ::Books::Book.where.not(id: @book.id).first
        second.update_columns(created_at: 1.day.ago)
        [@book, second].each { |book| evidence(book, {"wikidata_qid" => nil, "sources_failed" => []}) }
        ::Books::Author.where.not(id: @author.id).update_all(created_at: 1.year.ago)
        starts = []
        ::Workflows::Books::BookCategorize.stubs(:start).with { |_book, **kwargs| starts << kwargs[:start_after] }

        freeze_time do
          Recheck.call(dump_date: "d", apply: true)

          assert_equal [Time.current, Time.current + ::Services::Books::Categorize::Backfill::SPACING.seconds], starts
        end
      end

      test "an author holding a QID is skipped" do
        @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q5", source: :wikidata)
        assert_equal 0, Recheck.call(dump_date: "d", apply: true).data[:authors]
      end

      test "a dry run queues nothing and returns the counts" do
        evidence(@book, {"wikidata_qid" => nil, "sources_failed" => []})
        result = Recheck.call(dump_date: "d")

        assert_equal [1, 1, 0, 0], [result.data[:books], result.data[:authors], run_for(@book).count, author_runs.count]
      end
    end
  end
end
