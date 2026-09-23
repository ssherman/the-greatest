# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksDuplicatesRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:find_duplicates")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/duplicates.rake").to_s }
    end
    @task = Rake::Task["books:find_duplicates"]
    @task.reenable
  end

  test "aborts with usage, enqueueing nothing, when no size is given" do
    Books::FindDuplicatesJob.expects(:enqueue_ranked).never

    assert_output(nil, /usage: books:find_duplicates/) do
      assert_raises(SystemExit) { @task.invoke }
    end
  end

  test "aborts on a size that is neither a count nor all" do
    Books::FindDuplicatesJob.expects(:enqueue_ranked).never

    assert_output(nil, /usage/) do
      assert_raises(SystemExit) { @task.invoke("soon") }
    end
  end

  test "a count enqueues that many" do
    Books::FindDuplicatesJob.expects(:enqueue_ranked).with(limit: 100).returns(100)

    assert_output(/enqueued 100 ranked books/) { @task.invoke("100") }
  end

  test "all enqueues the whole ranking" do
    Books::FindDuplicatesJob.expects(:enqueue_ranked).with(limit: nil).returns(5)

    assert_output(/enqueued 5 ranked books/) { @task.invoke("all") }
  end
end
