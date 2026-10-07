# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class MatchProgressTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @list.wizard_manager.write_step!(step: "match", status: "running")
          end

          test "a running Match stays fresh after progress writes, so it is not read as stalled" do
            wizard_row(@list, position: 1, title: "A", wizard: {bucket: "matched"})
            wizard_row(@list, position: 2, title: "B")

            MatchProgress.call(list: @list)

            assert_equal "running", @list.reload.wizard_manager.step_status("match")
            assert_not @list.wizard_manager.step_stalled?("match")
          end

          test "while rows are pending it writes progress as decided rows out of all rows" do
            wizard_row(@list, position: 1, title: "A", wizard: {bucket: "matched"})
            wizard_row(@list, position: 2, title: "B", wizard: {bucket: "flagged"})
            wizard_row(@list, position: 3, title: "C")
            wizard_row(@list, position: 4, title: "D")
            wizard_row(@list, position: 5, title: "E", wizard: {bucket: "removed", settled: true})
            @list.list_items.create!(listable: books_books(:got), position: 6) # from before the wizard: not counted
            OnListTwice.expects(:call).never

            MatchProgress.call(list: @list)

            manager = @list.reload.wizard_manager
            assert_equal ["running", 50, 2, 4], [manager.step_status("match"), manager.step_progress("match"),
              manager.step_metadata("match")["processed_items"], manager.step_metadata("match")["total_items"]]
          end

          test "the last row completes the step and runs the on-list-twice pass once" do
            wizard_row(@list, position: 1, title: "A", wizard: {bucket: "matched"})
            OnListTwice.expects(:call).with(list: @list).once

            MatchProgress.call(list: @list)
            MatchProgress.call(list: @list) # a second finisher in the same run

            assert_equal ["completed", 100], [@list.reload.wizard_manager.step_status("match"), @list.wizard_manager.step_progress("match")]
          end

          test "a single-row re-match after completion runs the pass again" do
            wizard_row(@list, position: 1, title: "A", wizard: {bucket: "matched"})
            @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)
            OnListTwice.expects(:call).once

            MatchProgress.call(list: @list, single_row: true)
          end

          test "a single-row re-match never flips the step back to running" do
            wizard_row(@list, position: 1, title: "A")
            wizard_row(@list, position: 2, title: "B")
            @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)

            MatchProgress.call(list: @list, single_row: true)

            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end
        end
      end
    end
  end
end
