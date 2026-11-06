# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksCategorizeRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("books:categorize:backfill")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/categorize.rake").to_s }
    end
    @task = Rake::Task["books:categorize:backfill"]
    @task.reenable
    @apply = ENV.delete("APPLY")
    @book_ids = ENV.delete("BOOK_IDS")
    ::Services::Books::Categorize::Backfill.stubs(:candidates).returns(stub(count: 3600, limit: stub(count: 3600)))
  end

  teardown do
    ENV["APPLY"] = @apply
    ENV["BOOK_IDS"] = @book_ids
  end

  test "a dry run prints the count and the pacing, and enqueues nothing" do
    Books::CategorizeBackfillJob.expects(:perform_async).never
    assert_output(/3600 books would be planned \(scope origin_only, label v1\); about 8.0 hours of Wikimedia pacing\. Re-run with APPLY=1/) do
      @task.invoke("origin_only", "all", "v1")
    end
  end

  test "APPLY=1 enqueues one job" do
    ENV["APPLY"] = "1"
    Sidekiq::Testing.fake! do
      assert_output(/Queued Books::CategorizeBackfillJob/) { @task.invoke("origin_only", "100", "v1") }
      assert_equal 1, Books::CategorizeBackfillJob.jobs.size
      assert_equal ["origin_only", 100, "v1", nil], Books::CategorizeBackfillJob.jobs.first["args"]
      Books::CategorizeBackfillJob.clear
    end
  end

  test "BOOK_IDS is passed through" do
    ENV["APPLY"] = "1"
    ENV["BOOK_IDS"] = "4, 5"
    Sidekiq::Testing.fake! do
      capture_io { @task.invoke("origin_only", "all", "v1") }
      assert_equal ["origin_only", nil, "v1", [4, 5]], Books::CategorizeBackfillJob.jobs.first["args"]
      Books::CategorizeBackfillJob.clear
    end
  end

  test "a missing label, a bad limit or another scope aborts" do
    [["origin_only", "all", ""], ["origin_only", "0", "v1"], ["origin_only", "lots", "v1"], ["categories_only", "all", "v1"]].each do |args|
      @task.reenable
      assert_raises(SystemExit) { capture_io { @task.invoke(*args) } }
    end
  end

  test "origin report prints the parts and disagreements" do
    book = ::Books::Book.create!(title: "Rake Report Book", first_published_year: 1900, original_language: languages(:english))
    row = book.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply,
      facts: {"label" => "rk", "path" => "judge", "origin" => {"reason" => "disagreement", "country" => "British", "held" => ["American"]}})
    task = Rake::Task["books:origin:report"]
    task.reenable
    assert_output(/#{book.id} Rake Report Book: American -> British \(enrichment #{row.id}\)/) { task.invoke("rk") }
  end

  test "origin accept_disagreements is a dry run without APPLY and applies with it" do
    american = ::Books::Country.find_or_create_by!(name: "American")
    ::Books::Country.find_or_create_by!(name: "British")
    book = ::Books::Book.create!(title: "Rake Accept Book", first_published_year: 1900, original_language: languages(:english))
    book.countries << american
    row = book.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply,
      facts: {"label" => "rk", "origin" => {"reason" => "disagreement", "country" => "British", "held" => ["American"]}})
    task = Rake::Task["books:origin:accept_disagreements"]
    task.reenable
    capture_io { task.invoke("rk") }
    assert_equal ["American"], book.reload.countries.map(&:name)
    ENV["APPLY"] = "1"
    ENV["IDS"] = row.id.to_s
    task.reenable
    assert_output(/accepted 1/) { task.invoke("rk") }
    assert_equal ["British"], book.reload.countries.map(&:name)
  ensure
    ENV.delete("IDS")
  end
end
