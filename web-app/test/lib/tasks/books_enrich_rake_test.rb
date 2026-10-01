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
end
