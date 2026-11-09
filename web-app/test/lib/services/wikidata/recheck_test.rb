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

      test "queues the author job only for recent authors without a QID" do
        calls = []
        ::Books::Authors::WikidataJob.stubs(:perform_async).with { |*args| calls << args }

        result = Recheck.call(dump_date: "d", apply: true)

        assert_equal [[@author.id, true]], calls
        assert_equal 1, result.data[:authors]
      end

      test "an author holding a QID is skipped" do
        @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q5", source: :wikidata)
        ::Books::Authors::WikidataJob.expects(:perform_async).never

        assert_equal 0, Recheck.call(dump_date: "d", apply: true).data[:authors]
      end

      test "a dry run queues nothing and returns the counts" do
        evidence(@book, {"wikidata_qid" => nil, "sources_failed" => []})
        ::Books::Authors::WikidataJob.expects(:perform_async).never

        result = Recheck.call(dump_date: "d")

        assert_equal [1, 1, 0], [result.data[:books], result.data[:authors], run_for(@book).count]
      end
    end
  end
end
