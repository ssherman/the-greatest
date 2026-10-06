# frozen_string_literal: true

require "test_helper"

class Lists::Wizard::MatchJobTest < ActiveSupport::TestCase
  test "starts the match for the list" do
    list = lists(:books_list)
    ::Services::Lists::Wizard::Core::StartMatch.expects(:call).with(list: list, run_id: "run-1").returns(0)

    Lists::Wizard::MatchJob.new.perform(list.id, "run-1")
  end
end
