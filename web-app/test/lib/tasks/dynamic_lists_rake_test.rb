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

  # Real data: 50 books lists carry a `url` with a leading space, which fails
  # List's format validation -- running `adopt` against development aborted
  # partway through with a RecordInvalid on url. update_columns is the only
  # way to create that state in a test -- it skips validations, same as the
  # bad data's original write must have.
  test "adopt stamps a mapped list with a pre-existing invalid url" do
    @top.update_columns(url: " https://example.com")
    assert_not @top.valid?

    run_task("dynamic_lists:adopt")

    @top.reload
    assert @top.generated_year_top?
    assert_equal 2025, @top.auto_generated_year
    assert_equal " https://example.com", @top.url
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

  test "adopt handles a configuration with no secondary mapped list, without raising" do
    @config.update_column(:secondary_mapped_list_id, nil)

    run_task("dynamic_lists:adopt")

    assert @top.reload.generated_year_top?
    assert_equal 2025, @top.auto_generated_year
    assert_equal 2025, @config.reload.year
  end

  # Mocha's two independent `.once` expectations pass regardless of call order,
  # so a regression that hoists the terminal CalculateRankingsJob call above (or
  # into) the per-year loop -- recalculating the primary against stale mapped
  # lists, defeating the whole point of running each generator inline before it
  # -- would still pass. Recording invocation order with plain `.with { ... }`
  # blocks, as generate_dynamic_lists_test.rb does, pins the sequence instead.
  #
  # Stubs GenerateDynamicListsJob's instance `perform` (not `perform_async`):
  # the task now runs each year's generator inline and synchronously, in the
  # same process, so nothing is ever enqueued for it.
  test "regenerate runs each year configuration inline, then queues the single primary refresh, in that order" do
    @config.update_column(:year, 2025)
    call_order = []

    GenerateDynamicListsJob.any_instance.expects(:perform).with { |id, recalculate_primary|
      call_order << :generate
      id == @config.id && recalculate_primary == false
    }.once
    CalculateRankingsJob.expects(:perform_async).with { |id|
      call_order << :calculate
      id == ::Books::RankingConfiguration.default_primary.id
    }.once

    run_task("dynamic_lists:regenerate", "Books::RankingConfiguration")

    assert_equal [:generate, :calculate], call_order
  end

  # Defense in depth alongside the guard in Services::Lists::GenerateDynamicLists#guard_failure:
  # even if an operator sets `year` on the domain's primary configuration, the
  # rake task's own query must never hand it to the generator.
  test "regenerate excludes the primary configuration even when it carries a year" do
    @config.update_column(:year, 2025)
    primary = ranking_configurations(:books_global)
    primary.update_columns(year: 2024, primary_mapped_list_cutoff_limit: 100)

    generated_ids = []
    GenerateDynamicListsJob.any_instance.stubs(:perform).with { |id, _recalculate_primary|
      generated_ids << id
      true
    }
    CalculateRankingsJob.stubs(:perform_async)

    run_task("dynamic_lists:regenerate", "Books::RankingConfiguration")

    assert_equal [@config.id], generated_ids
    refute_includes generated_ids, primary.id
  end

  # Only one fixture in the whole suite (books_year_2025) has `year` set, so a
  # regression that swaps config_class.where for a bare RankingConfiguration.where
  # -- silently dropping the type scope, so regenerating Books would also queue
  # jobs for every other domain's year configurations -- passes every other test
  # in this file. This test creates a same-year configuration in a different
  # domain inline so that regression has something to catch.
  test "regenerate scopes to the given type and ignores other domains' year configurations" do
    @config.update_column(:year, 2025)
    other = ::Music::Albums::RankingConfiguration.create!(
      name: "Best Albums of 2025", year: 2025, global: true, primary: false
    )

    generated_ids = []
    GenerateDynamicListsJob.any_instance.stubs(:perform).with { |id, _recalculate_primary|
      generated_ids << id
      true
    }
    CalculateRankingsJob.stubs(:perform_async)

    run_task("dynamic_lists:regenerate", "Books::RankingConfiguration")

    assert_equal [@config.id], generated_ids
    refute_includes generated_ids, other.id
  end
end
