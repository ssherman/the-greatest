# frozen_string_literal: true

require "test_helper"

class Lists::Wizard::ImportJobTest < ActiveSupport::TestCase
  test "runs the import for the list with its adapter and the run id it was started with" do
    list = lists(:books_list)
    ::Services::Lists::Wizard::Core::ImportRows.expects(:call)
      .with(has_entries(list: list, run_id: "run-1", adapter: instance_of(::Services::Lists::Wizard::Books::Adapter))).returns(0)

    Lists::Wizard::ImportJob.new.perform(list.id, "run-1")
  end
end
