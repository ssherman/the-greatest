require "test_helper"
require "rake"

class EnrichmentQueueRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("enrichment_queue:fill")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/enrichment_queue.rake").to_s }
    end
    @task = Rake::Task["enrichment_queue:fill"]
    @task.reenable
    Services::EnrichmentQueue::Registry.stubs(:types).returns([EnrichmentQueueTestType])
  end

  teardown { EnrichmentQueueTestType.reset! }

  test "queues the job with the scope defaulting to ranked" do
    Sidekiq::Testing.fake! do
      assert_output(/Queued EnrichmentQueue::FillJob for books.test_type \(scope ranked\)/) { @task.invoke("books.test_type") }
      assert_equal [["books.test_type", "ranked", nil]], ::EnrichmentQueue::FillJob.jobs.map { |job| job["args"] }
      ::EnrichmentQueue::FillJob.clear
    end
  end

  test "passes scope and limit through" do
    Sidekiq::Testing.fake! do
      assert_output(/limit 25/) { @task.invoke("books.test_type", "all", "25") }
      assert_equal [["books.test_type", "all", 25]], ::EnrichmentQueue::FillJob.jobs.map { |job| job["args"] }
      ::EnrichmentQueue::FillJob.clear
    end
  end

  test "a blank or unknown kind aborts with the usage line and queues nothing" do
    ::EnrichmentQueue::FillJob.expects(:perform_async).never
    ["", "books.nope"].each do |kind|
      @task.reenable
      error = assert_raises(SystemExit) { capture_io { @task.invoke(kind) } }
      assert_equal 1, error.status
    end
  end

  test "a bad scope or limit aborts" do
    ::EnrichmentQueue::FillJob.expects(:perform_async).never
    [["books.test_type", "everything"], ["books.test_type", "all", "zero"]].each do |args|
      @task.reenable
      assert_raises(SystemExit) { capture_io { @task.invoke(*args) } }
    end
  end

  test "work queues one research job per claimable row up to the limit" do
    EnrichmentQueueTestType.paid = true
    books = [books_books(:war_and_peace), books_books(:crime_and_punishment), books_books(:got)]
    books.each { |book| ::EnrichmentRequest.create!(enrichable: book, kind: "books.test_type", reason: "missing") }
    work = Rake::Task["enrichment_queue:work"]
    Sidekiq::Testing.fake! do
      ::EnrichmentQueue::ResearchJob.clear
      work.reenable
      assert_output(/Queued 2 paid research job\(s\) for books.test_type \(3 claimable\)\. Each can spend one web search\./) { work.invoke("books.test_type", "2") }
      assert_equal [["books.test_type"]] * 2, ::EnrichmentQueue::ResearchJob.jobs.map { |job| job["args"] }
      ::EnrichmentQueue::ResearchJob.clear
      work.reenable
      assert_output(/Queued 3 paid research job\(s\)/) { work.invoke("books.test_type", "50") }
      assert_equal 3, ::EnrichmentQueue::ResearchJob.jobs.size
      ::EnrichmentQueue::ResearchJob.clear
    end
  end

  test "work aborts on an unknown kind, a missing or bad limit and a type without a paid path" do
    ::EnrichmentQueue::ResearchJob.expects(:perform_async).never
    work = Rake::Task["enrichment_queue:work"]
    EnrichmentQueueTestType.paid = true
    [["books.nope", "5"], ["books.test_type"], ["books.test_type", "0"], ["books.test_type", "many"]].each do |args|
      work.reenable
      assert_raises(SystemExit, args.inspect) { capture_io { work.invoke(*args) } }
    end
    EnrichmentQueueTestType.paid = false
    work.reenable
    assert_raises(SystemExit) { capture_io { work.invoke("books.test_type", "5") } }
  end
end
