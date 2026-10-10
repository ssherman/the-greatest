# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksAuthorNameKeysRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:refresh_author_name_keys")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/author_name_keys.rake").to_s }
    end
    @task = Rake::Task["books:refresh_author_name_keys"]
    @task.reenable
  end

  test "runs the refresh and prints its counts" do
    ::Services::Books::RefreshAuthorNameKeys.expects(:call).returns(
      ::Services::Books::RefreshAuthorNameKeys::Result.new(success?: true, data: {scanned: 7, updated: 2}, errors: [])
    )

    assert_output(/7 scanned, 2 updated/) { @task.invoke }
  end
end
