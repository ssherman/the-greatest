# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksAlternateTitlesRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("books:alternate_titles:backfill")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/alternate_titles.rake").to_s }
    end
    @task = Rake::Task["books:alternate_titles:backfill"]
    @task.reenable
  end

  test "runs the backfill and prints the count" do
    ::Services::AlternateTitles::Backfill.expects(:all).returns(5)

    assert_output(/5 rows created/) { @task.invoke }
  end
end
