# frozen_string_literal: true

require "test_helper"

module Workflows
  module Books
    module Steps
      class AuthorFactsTest < ActiveSupport::TestCase
        setup do
          @author = books_authors(:king)
          stub_workflow_dispatch
        end

        def call(options: {})
          run = AuthorEnrichment.start(@author, initiated_by: "test", options: options)
          AuthorFacts.new.call(step: run.step(:author_facts), run: run, target: @author)
        end

        def success(value)
          stub(success?: value, errors: ["no facts"])
        end

        test "runs the AI step with research on by default" do
          ::Services::Books::Authors::EnrichAuthor.expects(:call).with(author: @author, allow_research: true).returns(success(true))

          result = call

          assert_equal [:succeeded, "done"], [result.kind, result.outcome]
        end

        test "allow_research false travels from the run's options" do
          ::Services::Books::Authors::EnrichAuthor.expects(:call).with(author: @author, allow_research: false).returns(success(true))

          call(options: {allow_research: false})
        end

        test "a failed AI run raises so the coordinator retries it" do
          ::Services::Books::Authors::EnrichAuthor.stubs(:call).returns(success(false))

          error = assert_raises(StandardError) { call }

          assert_equal "Author enrichment failed for author #{@author.id}: no facts", error.message
        end
      end
    end
  end
end
