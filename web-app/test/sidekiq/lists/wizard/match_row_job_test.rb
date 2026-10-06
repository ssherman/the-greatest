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

  test "a row deleted since it was queued (a restart) is skipped" do
    ::Services::Lists::Wizard::Core::MatchRow.expects(:call).never

    Lists::Wizard::MatchRowJob.new.perform(0)
  end
end
