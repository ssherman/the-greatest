# frozen_string_literal: true

require "test_helper"

class Lists::Wizard::MatchRowJobTest < ActiveSupport::TestCase
  include ListWizardHelper

  test "matches the row with its list's adapter, passing single_row through" do
    row = wizard_row(wizard_list, position: 1, title: "Emma")
    ::Services::Lists::Wizard::Core::MatchRow.expects(:call)
      .with(has_entries(list_item: row, single_row: true, adapter: instance_of(::Services::Lists::Wizard::Books::Adapter)))

    Lists::Wizard::MatchRowJob.new.perform(row.id, true)
  end

  test "passes the attempt number through, defaulting to the first" do
    row = wizard_row(wizard_list, position: 1, title: "Emma")
    ::Services::Lists::Wizard::Core::MatchRow.expects(:call).with(has_entries(attempt: 3, single_row: false))
    Lists::Wizard::MatchRowJob.new.perform(row.id, false, 3)

    ::Services::Lists::Wizard::Core::MatchRow.expects(:call).with(has_entries(attempt: 1))
    Lists::Wizard::MatchRowJob.new.perform(row.id)
  end

  test "retries exhausted accepts the three-argument form a retry carries" do
    list = wizard_list
    list.wizard_manager.write_step!(step: "match", status: "running")
    row = wizard_row(list, position: 1, title: "Emma")

    Lists::Wizard::MatchRowJob.sidekiq_retries_exhausted_block.call({"args" => [row.id, false, 3]}, StandardError.new("db gone"))

    assert_equal ["flagged", ["match_failed"]], [::Services::Lists::Wizard::Core::RowState.new(row.reload).bucket, ::Services::Lists::Wizard::Core::RowState.new(row).reasons]
    assert_equal "completed", list.reload.wizard_manager.step_status("match")
  end

  test "a row deleted since it was queued (a restart) is skipped" do
    ::Services::Lists::Wizard::Core::MatchRow.expects(:call).never

    Lists::Wizard::MatchRowJob.new.perform(0)
  end

  test "a row whose retries ran out is flagged match_failed and progress runs, so the step can finish" do
    list = wizard_list
    list.wizard_manager.write_step!(step: "match", status: "running")
    row = wizard_row(list, position: 1, title: "Emma")

    Lists::Wizard::MatchRowJob.sidekiq_retries_exhausted_block.call({"args" => [row.id, false]}, StandardError.new("db gone"))

    state = ::Services::Lists::Wizard::Core::RowState.new(row.reload)
    assert_equal ["flagged", ["match_failed"], "db gone"], [state.bucket, state.reasons, state.error]
    assert_equal "completed", list.reload.wizard_manager.step_status("match")
  end

  test "retries exhausted leaves a row the admin already settled alone" do
    list = wizard_list
    row = wizard_row(list, position: 1, title: "Emma", wizard: {bucket: "removed", settled: true})

    Lists::Wizard::MatchRowJob.sidekiq_retries_exhausted_block.call({"args" => [row.id]}, StandardError.new("x"))

    assert_equal "removed", ::Services::Lists::Wizard::Core::RowState.new(row.reload).bucket
  end

  test "retries exhausted for a deleted row does nothing" do
    ::Services::Lists::Wizard::Core::MatchProgress.expects(:call).never

    assert_no_changes -> { ::ListItem.pluck(:id, :metadata, :listable_id) } do
      Lists::Wizard::MatchRowJob.sidekiq_retries_exhausted_block.call({"args" => [0]}, StandardError.new("x"))
    end
  end
end
