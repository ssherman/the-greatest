# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    module Steps
      class EvidenceTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:got)
          stub_workflow_dispatch
          freeze_time
        end

        def call(adapter = Evidence.new)
          run = BookEnrichment.start(@book, initiated_by: "test")
          adapter.call(step: run.step(:evidence), run: run, target: @book)
        end

        test "succeeds with the enrichment's outcome, its id and the QID the facts name" do
          enrichment = @book.enrichments.create!(kind: "books.evidence", outcome: :applied, facts: {"wikidata" => nil, "wikidata_qid" => "Q123"})
          ::Services::Books::Evidence::Gather.expects(:call).with(book: @book).returns(stub(data: {enrichment: enrichment}))

          result = call

          assert_equal [:succeeded, "applied", {"enrichment_id" => enrichment.id, "qid" => "Q123"}], [result.kind, result.outcome, result.result]
        end

        test "the qid is nil when the facts name none, whatever identifiers the book holds" do
          @book.identifiers.create!(identifier_type: :books_work_wikidata_qid, value: "Q999", source: :wikidata)
          enrichment = @book.enrichments.create!(kind: "books.evidence", outcome: :nothing_to_apply, facts: {"wikidata_qid" => nil})
          ::Services::Books::Evidence::Gather.stubs(:call).returns(stub(data: {enrichment: enrichment}))

          result = call

          assert_equal ["nothing_to_apply", {"enrichment_id" => enrichment.id, "qid" => nil}], [result.outcome, result.result]
        end

        test "a rate limit waits past retry_after plus jitter and writes no row" do
          ::Services::Books::Evidence::Gather.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("busy", retry_after: 60))
          adapter = Evidence.new
          adapter.stubs(:rand).returns(7)

          result = nil
          assert_no_difference -> { Enrichment.where(kind: "books.evidence").count } do
            result = call(adapter)
          end

          assert_equal [:wait, Time.current + 67], [result.kind, result.run_after]
        end
      end
    end
  end
end
