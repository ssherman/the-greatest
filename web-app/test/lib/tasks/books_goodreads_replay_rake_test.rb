# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksGoodreadsReplayRakeTest < ActiveSupport::TestCase
  REPLAY = Services::Books::GoodreadsReplay

  setup do
    # Load only this rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:goodreads_replay:load")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/goodreads_replay.rake").to_s }
    end
    Rake::Task.tasks.each(&:reenable)
  end

  def result(data)
    Struct.new(:success?, :data, :errors, keyword_init: true).new(success?: true, data: data, errors: [])
  end

  test "load prints the tally" do
    REPLAY::LoadImports.expects(:call).returns(result(tally: {loaded: 795, not_csv: 8}))

    assert_output(/loaded 795, not_csv 8/) { Rake::Task["books:goodreads_replay:load"].invoke }
  end
end
