# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksEnrichRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:enrich_missing")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/enrich.rake").to_s }
    end
    @task = Rake::Task["books:enrich_missing"]
    @task.reenable
  end

  test "a book whose only ledger row defers to its authors is still missing; an enriched one is not" do
    deferred = ::Books::Book.create!(title: "Deferred Book")
    ::Services::Books::DeferredEnrichment.defer!(deferred)
    # An applied run has no reason. A reason filter that is not NULL-safe
    # would drop this row and queue the book again.
    enriched = ::Books::Book.create!(title: "Enriched Book")
    enriched.enrichments.create!(kind: "books.book_facts", outcome: :applied)
    ::Books::EnrichBookJob.stubs(:perform_async)
    ::Books::EnrichBookJob.expects(:perform_async).with(deferred.id).once
    ::Books::EnrichBookJob.expects(:perform_async).with(enriched.id).never

    assert_output(/Enqueued/) { @task.invoke("100000") }
  end

  test "a deferred book counts as missing even with a description; a non-deferred described book does not" do
    # The Open Library provider can write a description onto a brand-new book
    # before AiEnrichment defers it to its new authors' chain. If that chain
    # breaks, the book must still be pickable here -- the no-description rule
    # only protects books that were never deferred.
    deferred_with_description = ::Books::Book.create!(title: "Deferred With Description")
    ::Services::Books::DeferredEnrichment.defer!(deferred_with_description)
    deferred_with_description.assign_description(source: :openlibrary, content: "An Open Library blurb.")
    deferred_with_description.save!

    described = ::Books::Book.create!(title: "Described Book")
    described.assign_description(source: :openlibrary, content: "Already has a description.")
    described.save!

    ::Books::EnrichBookJob.stubs(:perform_async)
    ::Books::EnrichBookJob.expects(:perform_async).with(deferred_with_description.id).once
    ::Books::EnrichBookJob.expects(:perform_async).with(described.id).never

    assert_output(/Enqueued/) { @task.invoke("100000") }
  end

  test "a book deferred and since enriched is not re-enqueued, even with a description" do
    # Pins the `.or`'s second branch to `missing.where(id: waiting)`, not a bare
    # `::Books::Book.where(id: waiting)`: `waiting` only checks that SOME row has
    # the deferral reason, not that it is the book's latest row, so dropping the
    # `missing` scope here would re-enqueue a book whose old deferral row was
    # superseded by a real, applied run.
    deferred_then_enriched = ::Books::Book.create!(title: "Deferred Then Enriched")
    ::Services::Books::DeferredEnrichment.defer!(deferred_then_enriched)
    deferred_then_enriched.enrichments.create!(kind: "books.book_facts", outcome: :applied)
    deferred_then_enriched.assign_description(source: :openlibrary, content: "Already enriched.")
    deferred_then_enriched.save!

    ::Books::EnrichBookJob.stubs(:perform_async)
    ::Books::EnrichBookJob.expects(:perform_async).with(deferred_then_enriched.id).never

    assert_output(/Enqueued/) { @task.invoke("100000") }
  end
end
