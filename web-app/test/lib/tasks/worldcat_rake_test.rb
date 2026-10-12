require "test_helper"
require "rake"

class WorldcatRakeTest < ActiveSupport::TestCase
  TASKS = %w[worldcat:export_isbns worldcat:vocabulary worldcat:map].freeze

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

  test "vocabulary writes the two CSVs under config/worldcat and prints the split" do
    result = Services::Books::WorldCat::VocabularySnapshot::Result.new(success?: true, data: {books_seen: 10, books_matched: 7, terms: {}, head: %w[a b], tail: %w[c]}, errors: [])
    Services::Books::WorldCat::VocabularySnapshot.expects(:call).with { |args| args[:out_dir].to_s.end_with?("config/worldcat") }.returns(result)
    assert_output(/7 of 10 books matched; 2 head terms, 1 tail terms/) { Rake::Task["worldcat:vocabulary"].invoke }
  end

  test "map runs the vocabulary mapping against the current genre list" do
    result = Services::Books::WorldCat::MapVocabulary::Result.new(success?: true, data: {mapped: 5, skipped_existing: 1, batches: 1}, errors: [])
    Services::Books::WorldCat::MapVocabulary.expects(:call).with { |args| args[:genres].include?("Fiction") && args[:out_path].to_s.end_with?("genre_map.yml") }.returns(result)
    assert_output(/mapped 5 terms \(1 already mapped\) in 1 batch/) { Rake::Task["worldcat:map"].invoke }
  end
end
