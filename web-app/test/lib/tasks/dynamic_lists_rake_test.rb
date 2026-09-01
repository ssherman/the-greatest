# frozen_string_literal: true

require "test_helper"
require "rake"

class DynamicListsRakeTest < ActiveSupport::TestCase
  setup do
    # Deliberately not `Rails.application.load_tasks`: that walks every
    # railtie's rake_tasks hook, and cssbundling-rails registers its
    # `lib/tasks/cssbundling/build.rake` through both its own hook and Rails'
    # generic per-engine `lib/tasks/**/*.rake` glob, so calling it a second
    # time in an already-booted process re-`load`s that file and Ruby warns
    # "already initialized constant Cssbundling::Tasks::LOCK_FILES" -- a new,
    # unrelated warning line in `bin/rails test`. Loading only the one file
    # this test needs avoids that entirely.
    unless Rake::Task.task_defined?("dynamic_lists:adopt")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      load Rails.root.join("lib/tasks/dynamic_lists.rake").to_s
    end

    @config = ranking_configurations(:books_year_2025)
    @top = ::Books::List.create!(name: "Legacy Top 2025", status: :active, year_published: 2025)
    @overflow = ::Books::List.create!(name: "Legacy Overflow 2025", status: :active, year_published: 2025)
    @config.update_columns(
      year: nil,
      secondary_mapped_list_cutoff_limit: nil,
      primary_mapped_list_id: @top.id,
      secondary_mapped_list_id: @overflow.id
    )
  end

  def run_task(name, *args)
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke(*args) }
  end

  test "adopt stamps kind and year on both lists from year_published" do
    run_task("dynamic_lists:adopt")

    assert @top.reload.generated_year_top?
    assert_equal 2025, @top.auto_generated_year
    assert @overflow.reload.generated_year_honorable_mention?
    assert_equal 2025, @overflow.auto_generated_year
  end

  test "adopt sets the configuration's year from the primary list" do
    run_task("dynamic_lists:adopt")

    assert_equal 2025, @config.reload.year
  end

  test "adopt defaults the secondary cutoff to 400" do
    run_task("dynamic_lists:adopt")

    assert_equal 400, @config.reload.secondary_mapped_list_cutoff_limit
  end

  test "adopt leaves an already-set secondary cutoff alone" do
    @config.update_column(:secondary_mapped_list_cutoff_limit, 250)

    run_task("dynamic_lists:adopt")

    assert_equal 250, @config.reload.secondary_mapped_list_cutoff_limit
  end

  test "adopt is idempotent" do
    run_task("dynamic_lists:adopt")
    run_task("dynamic_lists:adopt")

    assert_equal 2025, @top.reload.auto_generated_year
    assert_equal 1, ::Books::List.where(auto_generated_kind: :year_top, auto_generated_year: 2025).count
  end

  test "adopt skips a configuration whose primary list has no year_published" do
    @top.update_column(:year_published, nil)

    run_task("dynamic_lists:adopt")

    assert_nil @top.reload.auto_generated_kind
    assert_nil @config.reload.year
  end

  test "regenerate queues one job per year configuration and suppresses their primary refresh" do
    @config.update_column(:year, 2025)
    GenerateDynamicListsJob.expects(:perform_async).with(@config.id, false).once
    CalculateRankingsJob.expects(:perform_async).with(::Books::RankingConfiguration.default_primary.id).once

    run_task("dynamic_lists:regenerate", "Books::RankingConfiguration")
  end
end
