# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksGoodreadsRebuildRakeTest < ActiveSupport::TestCase
  REBUILD = Services::Books::GoodreadsRebuild

  setup do
    # Load only this rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:goodreads_rebuild:cohorts")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/goodreads_rebuild.rake").to_s }
    end
    Rake::Task.tasks.each(&:reenable)
  end

  test "cohorts prints the counts" do
    REBUILD::Cohort.expects(:counts).returns({"trusted" => 2, "derived" => 3, "only_on_user_favorites" => 1})

    assert_output(/post-import books: trusted 2, derived 3, only_on_user_favorites 1/) do
      Rake::Task["books:goodreads_rebuild:cohorts"].invoke
    end
  end
end
