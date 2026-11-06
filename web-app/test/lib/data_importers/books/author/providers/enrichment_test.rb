# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      module Providers
        class EnrichmentTest < ActiveSupport::TestCase
          test "plans an author enrichment run for the author and reports it" do
            stub_workflow_dispatch
            author = books_authors(:king)
            ::Books::Authors::WikidataJob.expects(:perform_async).never

            result = Enrichment.new.populate(author, query: nil)

            run = WorkflowRun.find_by!(enrichable: author, workflow: "books.author_enrichment")
            assert result.success?
            assert_equal [:author_enrichment_planned], result.data_populated
            assert_equal "author_importer", run.initiated_by
          end

          test "dispatches the run only after the surrounding transaction commits" do
            author = books_authors(:king)
            dispatched = []
            ::Workflows::Dispatcher.stubs(:dispatch).with { dispatched << true }
            dispatched_inside = nil

            ActiveRecord::Base.transaction(requires_new: true) do
              Enrichment.new.populate(author, query: nil)
              dispatched_inside = dispatched.size
            end

            assert_equal [0, 1], [dispatched_inside, dispatched.size]
          end

          test "an author with an active run keeps it" do
            stub_workflow_dispatch
            author = books_authors(:king)
            existing = ::Workflows::Books::AuthorEnrichment.start(author, initiated_by: "test")

            assert_no_difference -> { WorkflowRun.count } do
              assert Enrichment.new.populate(author, query: nil).success?
            end
            assert WorkflowRun.running.exists?(existing.id)
          end

          test "fails for an author that is not saved" do
            ::Workflows::Books::AuthorEnrichment.expects(:start).never

            result = Enrichment.new.populate(::Books::Author.new(name: "Unsaved"), query: nil)

            assert_not result.success?
            assert_includes result.errors, "Author must be persisted before queuing enrichment"
          end

          test "reports a planning error as a failure" do
            ::Workflows::Books::AuthorEnrichment.stubs(:start).raises(ArgumentError, "bad options")

            result = Enrichment.new.populate(books_authors(:king), query: nil)

            assert_not result.success?
            assert_match(/Author enrichment provider error/, result.errors.first)
          end
        end
      end
    end
  end
end
