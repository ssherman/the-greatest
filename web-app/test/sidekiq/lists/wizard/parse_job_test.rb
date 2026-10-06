# frozen_string_literal: true

require "test_helper"

class Lists::Wizard::ParseJobTest < ActiveSupport::TestCase
  test "runs the parse for the list with its adapter" do
    list = lists(:books_list)
    ::Services::Lists::Wizard::Core::ParseRows.expects(:call)
      .with(has_entries(list: list, adapter: instance_of(::Services::Lists::Wizard::Books::Adapter))).returns(0)

    Lists::Wizard::ParseJob.new.perform(list.id, "run-1")
  end
end
