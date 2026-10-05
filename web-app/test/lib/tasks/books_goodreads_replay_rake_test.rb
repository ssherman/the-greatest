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

  test "fix_slugs prints how many slug ids it recorded" do
    REPLAY::FixSlugIdentifiers.expects(:call).returns(result(recorded: 543))

    assert_output(/slug-form Goodreads ids: 543 verdicts/) { Rake::Task["books:goodreads_replay:fix_slugs"].invoke }
  end

  test "resolve queues both passes and says how many" do
    Books::GoodreadsReplay::ResolveEditionJob.expects(:enqueue_pending).returns({first_pass: 12, full_pass: 3})

    assert_output(/queued 12 editions for pass one and 3 for the full pass/) { Rake::Task["books:goodreads_replay:resolve"].invoke }
  end

  test "duplicates runs the author check, then the book rule, and reports both" do
    order = sequence("duplicates")
    REPLAY::FindAuthorDuplicates.expects(:call).in_sequence(order).returns(result(tally: {checked: 3188}, ai_calls: 3188))
    REPLAY::FindBookDuplicates.expects(:call).in_sequence(order).returns(result(recorded: 41))

    assert_output(/author name groups: checked 3188 \(3188 AI calls\)\nbook pairs: 41 merge verdicts/) do
      Rake::Task["books:goodreads_replay:duplicates"].invoke
    end
  end

  test "junk reports both kinds" do
    REPLAY::FindJunk.expects(:call).returns(result(authorless: 37, orphaned: 4))

    assert_output(/mark_provisional verdicts: 37 authorless, 4 with no support after relinks/) { Rake::Task["books:goodreads_replay:junk"].invoke }
  end

  test "apply aborts with the gate's reason while auto_apply is off" do
    REPLAY::ApplyVerdicts.expects(:call).returns(Struct.new(:success?, :data, :errors, keyword_init: true)
      .new(success?: false, data: {tally: {}}, errors: ["auto_apply is off (config.x.goodreads_replay.auto_apply); nothing was applied"]))

    assert_output(nil, /auto_apply is off/) { assert_raises(SystemExit) { Rake::Task["books:goodreads_replay:apply"].invoke } }
  end

  test "apply prints what it applied" do
    REPLAY::ApplyVerdicts.expects(:call).returns(result(tally: {"merge_books applied" => 2}, ranking_configuration_ids: [1]))

    assert_output(/applied verdicts: merge_books applied 2; ranking recalculations queued: 1/) do
      Rake::Task["books:goodreads_replay:apply"].invoke
    end
  end
end
