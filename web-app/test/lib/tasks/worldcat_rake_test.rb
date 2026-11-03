require "test_helper"
require "rake"

class WorldcatRakeTest < ActiveSupport::TestCase
  TASKS = %w[worldcat:export_isbns worldcat:vocabulary worldcat:map worldcat:report worldcat:apply_aliases worldcat:backfill].freeze

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

  test "report writes the data-quality page" do
    result = Services::Books::WorldCat::MappingReport::Result.new(success?: true, data: {top: [], unplaced: [1, 2], counts: {genre: 3, audience: 4, subject: 1, drop: 2}}, errors: [])
    Services::Books::WorldCat::MappingReport.expects(:call).with { |args| args[:out_path].to_s.end_with?("docs/data-quality/worldcat-genre-mapping.md") }.returns(result)
    assert_output(/3 genre, 4 audience, 1 subject, 2 drop; 2 terms with no genre/) { Rake::Task["worldcat:report"].invoke }
  end

  test "apply_aliases reports what it added" do
    result = Services::Books::WorldCat::ApplyAliases::Result.new(success?: true, data: {categories_updated: 2, aliases_added: 5, missing_genres: ["Nope"]}, errors: [])
    Services::Books::WorldCat::ApplyAliases.expects(:call).returns(result)
    assert_output(/added 5 aliases on 2 genres; genres named by the map but missing: Nope/) { Rake::Task["worldcat:apply_aliases"].invoke }
  end

  test "backfill[verified] queues one run over every verified book" do
    Books::WorldCatBackfillJob.expects(:perform_async).with(nil, instance_of(String))
    assert_output(/queued WorldCat backfill run .*: every book with a verified ISBN-13/) { Rake::Task["worldcat:backfill"].invoke("verified") }
  end

  test "backfill[<count>] queues a limited run" do
    Books::WorldCatBackfillJob.expects(:perform_async).with(100, instance_of(String))
    assert_output(/: 100 books/) { Rake::Task["worldcat:backfill"].invoke("100") }
  end

  test "backfill[all] is refused and points at verified" do
    Books::WorldCatBackfillJob.expects(:perform_async).never
    assert_output(nil, /worldcat:backfill\[verified\]/) { assert_raises(SystemExit) { Rake::Task["worldcat:backfill"].invoke("all") } }
  end

  test "backfill aborts with usage on anything else" do
    Books::WorldCatBackfillJob.expects(:perform_async).never
    assert_output(nil, /usage: worldcat:backfill/) { assert_raises(SystemExit) { Rake::Task["worldcat:backfill"].invoke("soon") } }
  end
end
