# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    module Steps
      class WikidataTest < ActiveSupport::TestCase
        setup do
          @author = books_authors(:king)
          stub_workflow_dispatch
          freeze_time
        end

        def author_run(options: {})
          AuthorEnrichment.start(@author, initiated_by: "test", options: options)
        end

        def outcome(value)
          ::Services::Books::Authors::EnrichFromWikidata::Result.new(success?: value != :failed, data: {outcome: value}, errors: [])
        end

        def call(adapter, run)
          adapter.call(step: run.step(:wikidata), run: run, target: @author)
        end

        test "records the service outcome as the step outcome" do
          ::Services::Books::Authors::EnrichFromWikidata.expects(:call).with(author: @author, refresh: false).returns(outcome(:unmatched))

          result = call(Wikidata.new(refresh_from: :options), author_run)

          assert_equal [:succeeded, "unmatched"], [result.kind, result.outcome]
        end

        test "a failed service outcome is a business outcome, not an error" do
          ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:failed))

          result = call(Wikidata.new(refresh_from: :options), author_run)

          assert_equal [:succeeded, "failed"], [result.kind, result.outcome]
        end

        test "refresh_from options reads the run's refresh option" do
          ::Services::Books::Authors::EnrichFromWikidata.expects(:call).with(author: @author, refresh: true).returns(outcome(:matched))

          call(Wikidata.new(refresh_from: :options), author_run(options: {refresh: true}))
        end

        test "a fixed refresh ignores the run's options" do
          ::Services::Books::Authors::EnrichFromWikidata.expects(:call).with(author: @author, refresh: true).returns(outcome(:matched))

          call(Wikidata.new(refresh: true), author_run)
        end

        test "a rate limit waits past retry_after plus jitter" do
          ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("busy", retry_after: 60))
          adapter = Wikidata.new(refresh_from: :options)
          adapter.stubs(:rand).returns(7)

          result = call(adapter, author_run)

          assert_equal [:wait, 67.seconds.from_now, false], [result.kind, result.run_after, result.release]
        end
      end
    end
  end
end
