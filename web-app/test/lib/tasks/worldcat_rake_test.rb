require "test_helper"
require "rake"

class WorldcatRakeTest < ActiveSupport::TestCase
  TASKS = %w[worldcat:export_isbns].freeze

  setup do
    unless Rake::Task.task_defined?("worldcat:export_isbns")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/worldcat.rake").to_s }
    end
    TASKS.each { |name| Rake::Task[name].reenable }
  end

  test "export_isbns writes the file and reports the count" do
    path = Rails.root.join("tmp", "worldcat_rake_test_isbns.txt").to_s
    Books::WorldCat::IsbnExport.expects(:call).with { |args| args[:io].respond_to?(:puts) }.returns(3)
    assert_output(/wrote 3 ISBNs to #{Regexp.escape(path)}/) { Rake::Task["worldcat:export_isbns"].invoke(path) }
  ensure
    File.delete(path) if path && File.exist?(path)
  end
end
